# frozen_string_literal: true

require "bigdecimal"

# Master (whole-book) aggregation. Sums per-portfolio accounting and — crucially —
# nets internal portfolio-to-portfolio transfers to zero, so they never affect
# Master external capital, TWR or XIRR (spec F/G/R/AN).
#
#   Master NAV        = Σ portfolio NAV
#   External contribs = Σ contributions_external (transfers excluded)
#   External withdraw = Σ withdrawals_external   (transfers excluded)
#   Internal transfers= Σ transfers_out (== Σ transfers_in) — informational only
class PortfolioMasterAccountingService
  Result = Struct.new(
    :rows, :reporting_currency_id,
    :nav, :cash, :holdings_value,
    :external_contributions, :external_withdrawals, :net_external, :internal_transfers,
    :realized_pnl, :unrealized_pnl, :dividend_income, :fees,
    :total_wealth, :net_profit, :simple_roi,
    :buy_turnover, :sell_turnover,
    keyword_init: true
  )

  class << self
    def call(portfolios = nil, base_id: nil)
      new(base_id: base_id).call(portfolios)
    end
  end

  def initialize(base_id: nil)
    @base_id = base_id || Currency.reporting_currency_id
  end

  def call(portfolios = nil)
    portfolios ||= Portfolio.all.to_a
    rows = PortfolioAccountingService.for_all(portfolios, base_id: @base_id)

    nav = sum(rows, :nav)
    external_contributions = sum(rows, :contributions_external)
    external_withdrawals = sum(rows, :withdrawals_external)
    internal_transfers = sum(rows, :transfers_out) # == Σ transfers_in
    total_wealth = nav + external_withdrawals
    net_profit = total_wealth - external_contributions
    simple_roi = external_contributions.positive? ? (net_profit / external_contributions) * 100 : nil

    Result.new(
      rows: rows, reporting_currency_id: @base_id,
      nav: nav, cash: sum(rows, :cash), holdings_value: sum(rows, :holdings_value),
      external_contributions: external_contributions, external_withdrawals: external_withdrawals,
      net_external: external_contributions - external_withdrawals, internal_transfers: internal_transfers,
      realized_pnl: sum(rows, :realized_pnl), unrealized_pnl: sum(rows, :unrealized_pnl),
      dividend_income: sum(rows, :dividend_income), fees: sum(rows, :fees),
      total_wealth: total_wealth, net_profit: net_profit, simple_roi: simple_roi,
      buy_turnover: sum(rows, :buy_turnover), sell_turnover: sum(rows, :sell_turnover)
    )
  end

  private

  def sum(rows, field)
    rows.sum { |r| r.public_send(field).to_d }
  end
end
