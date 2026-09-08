# frozen_string_literal: true

require "bigdecimal"

# Annualised Sharpe ratio for a portfolio, computed from its daily value
# snapshots. Per-interval returns are cash-flow adjusted (buys add cost, sells
# remove proceeds) so contributions/withdrawals aren't mistaken for performance.
#
#   sharpe = (annualised return - risk-free rate) / annualised volatility
#
# Needs enough history; returns { insufficient: true } until MIN_RETURNS intervals
# are available.
class PortfolioSharpeService
  MIN_RETURNS = 8

  class << self
    def call(portfolio, as_of: Date.current)
      new(portfolio, as_of).call
    end
  end

  def initialize(portfolio, as_of)
    @portfolio = portfolio
    @as_of = as_of
  end

  def call
    snaps = @portfolio.portfolio_snapshots.where("date <= ?", @as_of).order(:date).pluck(:date, :total_value)
    return insufficient(snaps.size) if snaps.size <= MIN_RETURNS

    base_id = Currency.reporting_currency_id
    returns = []
    gaps = []
    snaps.each_cons(2) do |(d0, v0), (d1, v1)|
      v0 = v0.to_d
      next unless v0.positive?

      flow = net_investment_flow(d0, d1, base_id)
      returns << ((v1.to_d - flow - v0) / v0).to_f
      gaps << (d1 - d0).to_i
    end
    return insufficient(returns.size) if returns.size < MIN_RETURNS

    n = returns.size
    mean = returns.sum / n
    variance = returns.sum { |r| (r - mean)**2 } / (n - 1)
    sd = Math.sqrt(variance)

    avg_gap = gaps.sum.to_f / gaps.size
    periods_per_year = avg_gap.positive? ? (365.0 / avg_gap) : 252.0

    ann_return = mean * periods_per_year
    ann_vol = sd * Math.sqrt(periods_per_year)
    rf = risk_free_rate

    sharpe = ann_vol.positive? ? ((ann_return - rf) / ann_vol) : nil

    {
      insufficient: false,
      sharpe: sharpe,
      ann_return_pct: ann_return * 100,
      ann_vol_pct: ann_vol * 100,
      risk_free_pct: rf * 100,
      periods: n
    }
  end

  private

  def insufficient(count)
    { insufficient: true, sharpe: nil, periods: [count - 1, 0].max, min_required: MIN_RETURNS }
  end

  def risk_free_rate
    (AnalyticsSetting.record.risk_free_rate_pct.to_d / 100).to_f
  rescue StandardError
    0.0
  end

  # Net capital moved into holdings during (d0, d1]: buys add, sells remove,
  # converted to the reporting currency. Corporate actions (dividends, stock
  # dividends) are treated as return, not flow.
  def net_investment_flow(d0, d1, base_id)
    @portfolio.portfolio_transactions
      .joins(:transaction_type)
      .where(transaction_types: { key: %w[buy sell] })
      .where("transactions.date > ? AND transactions.date <= ?", d0, d1)
      .includes(:transaction_type)
      .sum do |t|
        amt = CurrencyConversionService.convert(t.total_amount.to_d, t.currency_id, base_id)
        t.transaction_type.key == "buy" ? amt.to_d : -amt.to_d
      end
  end
end
