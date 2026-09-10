# frozen_string_literal: true

require "bigdecimal"

# Classifies portfolio cash flows for time-weighted performance.
#
# In this app a portfolio holds only securities; its tracked value is holdings
# market value. Capital therefore enters a portfolio through a BUY (cash leaves a
# wallet, becomes holdings) and leaves through a SELL. So for a portfolio's
# holdings performance:
#
#   external_cash_flow(day) = SUM(buy total) - SUM(sell total)      [reporting ccy]
#   dividend_income(day)    = SUM(cash_dividend total)              [reporting ccy]
#
# Buys/sells are external capital movements (not investment return); dividends are
# internal investment income (they DO count as return). stock_dividend adds shares
# and shows up as return through the value series, so it is not a cash flow here.
#
# Wallet deposits/withdrawals/transfers are NOT portfolio-scoped and never appear.
# A portfolio-to-portfolio capital move is a SELL in one + a BUY in the other; when
# both portfolios are in the consolidated set their flows cancel (spec #21/#22).
class PortfolioCashFlowService
  EXTERNAL_KEYS = %w[buy sell].freeze
  DIVIDEND_KEYS = %w[cash_dividend].freeze

  Day = Struct.new(:external, :dividend, keyword_init: true)

  class << self
    def call(portfolio_ids, base_id: nil)
      new(portfolio_ids, base_id: base_id).call
    end

    # Convenience: the same, keyed by day, for a single portfolio.
    def for_portfolio(portfolio, base_id: nil)
      call([portfolio.id], base_id: base_id)
    end
  end

  def initialize(portfolio_ids, base_id:)
    @portfolio_ids = Array(portfolio_ids)
    @base_id = base_id || Currency.reporting_currency_id
  end

  # => { Date => Day(external:, dividend:) } in reporting currency.
  def call
    days = Hash.new { |h, k| h[k] = Day.new(external: 0.to_d, dividend: 0.to_d) }
    return days if @portfolio_ids.empty?

    PortfolioTransaction
      .joins(:transaction_type)
      .includes(:asset)
      .where(portfolio_id: @portfolio_ids)
      .where(transaction_types: { key: EXTERNAL_KEYS + DIVIDEND_KEYS })
      .find_each do |tx|
        next if tx.asset&.wallet?

        key = tx.transaction_type.key
        amount = reporting_amount(tx)
        d = tx.date.to_date
        case key
        when "buy"  then days[d].external += amount
        when "sell" then days[d].external -= amount
        when "cash_dividend" then days[d].dividend += amount
        end
      end

    days
  end

  private

  def reporting_amount(tx)
    amt = tx.total_amount.to_d
    return amt if @base_id.blank? || tx.currency_id == @base_id

    CurrencyConversionService.convert(amt, tx.currency_id, @base_id).to_d
  rescue StandardError
    tx.total_amount.to_d
  end
end
