# frozen_string_literal: true

require "bigdecimal"

# Risk / efficiency metrics computed from the SAME cash-flow-adjusted daily return
# series the performance engine produces (PortfolioPerformanceService#daily_for).
# Never computed from raw portfolio values, so deposits/withdrawals and internal
# transfers create no artificial volatility or drawdown. Consolidated ("All
# portfolios") uses one consolidated return series — metrics are never averaged
# across portfolios.
#
# Each metric has a minimum-history rule; below it the value is nil (rendered
# "N/A — insufficient history") rather than an annualised, misleading number.
class PortfolioRiskService
  TRADING_DAYS = 252 # trading days per year (configurable constant)

  # Minimum observations before a metric is considered meaningful.
  MIN_VOL_DAYS     = 20   # trading days
  MIN_SHARPE_DAYS  = 30
  MIN_SORTINO_DAYS = 30
  MIN_MDD_DAYS     = 5
  MIN_CALMAR_DAYS  = 90   # CALENDAR days of span

  RISK_PERIODS = [
    [:m1, "1M"], [:m3, "3M"], [:m6, "6M"], [:ytd, "YTD"], [:y1, "1Y"], [:inception, "Since inception"]
  ].freeze

  Result = Struct.new(
    :n_returns, :span_days,
    :volatility, :sharpe, :sortino,
    :max_drawdown, :dd_peak_date, :dd_trough_date, :dd_recovery_date, :current_drawdown,
    :calmar, :annualized_return, :total_return,
    :risk_free_annual,
    keyword_init: true
  )

  class << self
    # Compute metrics from an ordered DayReturn array (as returned by the
    # performance engine). daily entries expose .date and .daily_return (fraction,
    # nil on the first day). Only [from, to] is used when given (risk period /
    # common-start window).
    def from_daily(daily, risk_free_annual:, from: nil, to: nil, trading_days: TRADING_DAYS)
      new(risk_free_annual: risk_free_annual, trading_days: trading_days).from_daily(daily, from: from, to: to)
    end
  end

  def initialize(risk_free_annual:, trading_days: TRADING_DAYS)
    @rf_annual = risk_free_annual.to_f
    @trading_days = trading_days
  end

  def from_daily(daily, from: nil, to: nil)
    window = daily
    window = window.select { |d| d.date >= from } if from
    window = window.select { |d| d.date <= to } if to

    # Daily return observations (skip the first day's nil return).
    obs = window.filter_map { |d| d.daily_return&.to_f }
    n = obs.size
    span = window.size >= 2 ? (window.last.date - window.first.date).to_i : 0

    return empty_result(span) if n.zero?

    rf_daily = @rf_annual / 100.0 / @trading_days
    sd = std(obs)
    mean = n.positive? ? obs.sum / n : 0.0

    volatility = n >= MIN_VOL_DAYS ? sd * Math.sqrt(@trading_days) : nil

    sharpe =
      if n >= MIN_SHARPE_DAYS && sd.positive?
        excess = obs.map { |r| r - rf_daily }
        (excess.sum / n) / sd * Math.sqrt(@trading_days)
      end

    sortino =
      if n >= MIN_SORTINO_DAYS
        downside = obs.map { |r| r - rf_daily }.select(&:negative?)
        if downside.empty?
          :no_downside # distinct from nil: enough history but no negative days
        else
          dd = Math.sqrt(downside.sum { |x| x**2 } / n)
          dd.positive? ? ((obs.map { |r| r - rf_daily }.sum / n) / dd * Math.sqrt(@trading_days)) : nil
        end
      end

    dd = drawdown(window)
    max_dd = n >= MIN_MDD_DAYS ? dd[:max] : nil

    total_ret = compounded_total(obs)
    ann_ret = annualized(total_ret, span)
    calmar =
      if span >= MIN_CALMAR_DAYS && max_dd && max_dd.negative? && ann_ret
        ann_ret / max_dd.abs
      end

    Result.new(
      n_returns: n, span_days: span,
      volatility: volatility, sharpe: sharpe, sortino: sortino,
      max_drawdown: max_dd,
      dd_peak_date: max_dd ? dd[:peak_date] : nil,
      dd_trough_date: max_dd ? dd[:trough_date] : nil,
      dd_recovery_date: max_dd ? dd[:recovery_date] : nil,
      current_drawdown: n >= MIN_MDD_DAYS ? dd[:current] : nil,
      calmar: calmar, annualized_return: (span >= MIN_CALMAR_DAYS ? ann_ret : nil), total_return: total_ret,
      risk_free_annual: @rf_annual
    )
  end

  private

  def empty_result(span)
    Result.new(n_returns: 0, span_days: span, volatility: nil, sharpe: nil, sortino: nil,
               max_drawdown: nil, dd_peak_date: nil, dd_trough_date: nil, dd_recovery_date: nil,
               current_drawdown: nil, calmar: nil, annualized_return: nil, total_return: 0.0,
               risk_free_annual: @rf_annual)
  end

  # Sample standard deviation (n-1). 0.0 for < 2 obs.
  def std(obs)
    n = obs.size
    return 0.0 if n < 2

    mean = obs.sum / n
    Math.sqrt(obs.sum { |r| (r - mean)**2 } / (n - 1))
  end

  def compounded_total(obs)
    obs.reduce(1.0) { |acc, r| acc * (1 + r) } - 1
  end

  # Annualise a window's total return by its calendar span.
  def annualized(total_return, span_days)
    return nil if span_days < 1

    ((1 + total_return)**(365.0 / span_days)) - 1
  rescue StandardError
    nil
  end

  # Compounded index drawdown path. Builds index_t = 100 * PRODUCT(1+r), tracks the
  # running peak, and reports the deepest (index/peak - 1). Deposits never enter
  # here because r is the cash-flow-adjusted daily return.
  def drawdown(window)
    idx = 100.0
    peak = 100.0
    peak_date = window.first&.date
    max_dd = 0.0
    cur_peak_date = peak_date
    dd_peak_date = peak_date
    trough_date = peak_date
    recovery_date = nil
    recovered_from = nil

    window.each do |d|
      r = d.daily_return&.to_f
      idx *= (1 + r) if r

      if idx >= peak
        peak = idx
        cur_peak_date = d.date
        # a new high recovers any open drawdown
        if recovered_from && recovery_date.nil?
          recovery_date = d.date
        end
      else
        dd = idx / peak - 1
        if dd < max_dd
          max_dd = dd
          dd_peak_date = cur_peak_date
          trough_date = d.date
          recovery_date = nil
          recovered_from = max_dd
        end
      end
    end

    current = peak.positive? ? (idx / peak - 1) : 0.0
    { max: max_dd, peak_date: dd_peak_date, trough_date: trough_date,
      recovery_date: recovery_date, current: current }
  end
end
