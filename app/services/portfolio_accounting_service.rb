# frozen_string_literal: true

require "bigdecimal"

# THE single source of truth for portfolio-boundary accounting (spec A–I, P).
# Everything else — dashboard, performance, reports, snapshots — reads from here;
# nothing recomputes accounting independently (spec AR/AN).
#
# Core principle: capital contribution = money crossing the portfolio boundary
# (contributions/withdrawals/transfers), NOT buy transactions. Buys/sells are
# internal capital recycling: they move portfolio cash <-> holdings, leaving NAV
# unchanged.
#
#   cash        = opening_cash + post-migration tx cash effects + cash-flow effects
#   NAV         = cash + holdings market value
#   contributions (all) = opening_capital + contributions + transfer_in
#   withdrawals   (all) = withdrawals + transfer_out
#   total_wealth  = NAV + cumulative_withdrawals
#   net_profit    = total_wealth - cumulative_contributions
#   simple_roi    = net_profit / cumulative_contributions
#
# Transfers count as external for the individual portfolio but net to zero at the
# Master level (see PortfolioMasterAccountingService).
class PortfolioAccountingService
  EPOCH = Date.new(1900, 1, 1)

  # Portfolio-scoped transaction cash effects (all internal recycling).
  CASH_TX_SIGN = { "buy" => -1, "sell" => 1, "cash_dividend" => 1, "deduction" => -1 }.freeze

  Result = Struct.new(
    :portfolio, :reporting_currency_id, :migrated,
    :holdings_value, :cash, :nav,
    :contributions, :withdrawals, :net_external,
    :contributions_external, :withdrawals_external, :transfers_in, :transfers_out,
    :realized_pnl, :unrealized_pnl, :dividend_income, :fees,
    :total_wealth, :net_profit, :simple_roi,
    :buy_turnover, :sell_turnover, :turnover_ratio,
    keyword_init: true
  )

  class << self
    def call(portfolio, base_id: nil)
      new(base_id: base_id).call(portfolio)
    end

    def for_all(portfolios = nil, base_id: nil)
      svc = new(base_id: base_id)
      (portfolios || Portfolio.all).map { |p| svc.call(p) }
    end
  end

  def initialize(base_id: nil)
    @base_id = base_id || Currency.reporting_currency_id
  end

  def call(portfolio)
    opening = portfolio.opening_capital
    migrated = opening.present?
    migration_on = opening&.migration_on || EPOCH
    open_cash = opening&.opening_cash.to_d
    open_capital = opening&.opening_capital.to_d

    summary = PortfolioStatsService.summary(portfolio)
    holdings_value = summary[:total_value].to_d

    tx_cash = post_migration_tx_cash(portfolio, migration_on)
    flows = flow_totals(portfolio)

    cash = open_cash + tx_cash + flows[:cash]
    nav = cash + holdings_value

    contributions = open_capital + flows[:contributions]
    withdrawals = flows[:withdrawals]
    net_external = contributions - withdrawals

    total_wealth = nav + withdrawals
    net_profit = total_wealth - contributions
    simple_roi = contributions.positive? ? (net_profit / contributions) * 100 : nil

    buy_t = turnover(portfolio, "buy")
    sell_t = turnover(portfolio, "sell")
    turnover_ratio = nav.positive? ? ([buy_t, sell_t].min / nav) * 100 : nil

    Result.new(
      portfolio: portfolio, reporting_currency_id: @base_id, migrated: migrated,
      holdings_value: holdings_value, cash: cash, nav: nav,
      contributions: contributions, withdrawals: withdrawals, net_external: net_external,
      contributions_external: open_capital + flows[:ext_contributions], withdrawals_external: flows[:ext_withdrawals],
      transfers_in: flows[:transfers_in], transfers_out: flows[:transfers_out],
      realized_pnl: summary[:realised_gain].to_d, unrealized_pnl: summary[:unrealised_gain].to_d,
      dividend_income: dividends(portfolio), fees: fees(portfolio),
      total_wealth: total_wealth, net_profit: net_profit, simple_roi: simple_roi,
      buy_turnover: buy_t, sell_turnover: sell_t, turnover_ratio: turnover_ratio
    )
  end

  private

  # Net cash effect of portfolio-scoped transactions dated AFTER migration_on.
  def post_migration_tx_cash(portfolio, migration_on)
    total = 0.to_d
    portfolio.portfolio_transactions
             .joins(:transaction_type)
             .where(transaction_types: { key: CASH_TX_SIGN.keys })
             .where("transactions.date > ?", migration_on.end_of_day)
             .find_each do |tx|
      sign = CASH_TX_SIGN[tx.transaction_type.key]
      total += reporting(tx.total_amount, tx.currency_id) * sign
    end
    total
  end

  # Cash-flow effects (contributions/withdrawals/transfers) split for reuse.
  def flow_totals(portfolio)
    cash = 0.to_d
    contributions = 0.to_d # includes transfer_in
    withdrawals = 0.to_d   # includes transfer_out
    ext_contributions = 0.to_d
    ext_withdrawals = 0.to_d
    transfers_in = 0.to_d
    transfers_out = 0.to_d
    portfolio.portfolio_cash_flows.find_each do |f|
      amt = reporting(f.amount, f.currency_id)
      cash += amt * f.cash_sign
      contributions += amt if f.contribution?
      withdrawals += amt if f.withdrawal?
      case f.kind
      when "contribution" then ext_contributions += amt
      when "withdrawal" then ext_withdrawals += amt
      when "transfer_in" then transfers_in += amt
      when "transfer_out" then transfers_out += amt
      end
    end
    { cash: cash, contributions: contributions, withdrawals: withdrawals,
      ext_contributions: ext_contributions, ext_withdrawals: ext_withdrawals,
      transfers_in: transfers_in, transfers_out: transfers_out }
  end

  def turnover(portfolio, key)
    total = 0.to_d
    portfolio.portfolio_transactions.joins(:transaction_type)
             .where(transaction_types: { key: key })
             .find_each { |tx| total += reporting(tx.total_amount, tx.currency_id) }
    total
  end

  def dividends(portfolio)
    total = 0.to_d
    portfolio.portfolio_transactions.joins(:transaction_type)
             .where(transaction_types: { key: "cash_dividend" })
             .find_each { |tx| total += reporting(tx.total_amount, tx.currency_id) }
    total
  end

  def fees(portfolio)
    total = 0.to_d
    portfolio.portfolio_transactions.joins(:transaction_type)
             .where(transaction_types: { key: "deduction" })
             .find_each { |tx| total += reporting(tx.total_amount, tx.currency_id) }
    total
  end

  def reporting(amount, currency_id)
    a = amount.to_d
    return a if @base_id.blank? || currency_id == @base_id

    CurrencyConversionService.convert(a, currency_id, @base_id).to_d
  rescue StandardError
    amount.to_d
  end
end
