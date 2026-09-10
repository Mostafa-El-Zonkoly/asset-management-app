# frozen_string_literal: true

require "bigdecimal"

# Time-weighted portfolio performance across trailing and calendar periods.
#
# Method (documented per spec #12/#15):
#   * A portfolio's value = its holdings market value (reporting currency). Capital
#     enters via BUY and leaves via SELL, so those are the EXTERNAL cash flows;
#     dividends are internal income. Deposits/withdrawals to wallets are not
#     portfolio-scoped and never count as investment return.
#   * Daily investment return uses Modified Dietz with same-day flows weighted 0.5
#     (timing unknown at day granularity):
#         r_day = (V_end - V_start - F + D) / (V_start + 0.5*F)
#     where F = net external flow (buys - sells), D = dividend income that day.
#   * A period return COMPOUNDS daily returns:  PRODUCT(1 + r_day) - 1  (never a sum).
#   * Values come from STORED snapshots (role = all) or a reconstructed role series
#     (role = base/temporary), so history never changes when live prices update.
#   * Combined view sums per-portfolio value/flow series; internal portfolio-to-
#     portfolio moves (a sell in one + buy in another) cancel (#22).
#   * Insufficient history for a period => nil (rendered "N/A"), never a fabricated
#     number.
class PortfolioPerformanceService
  HALF = BigDecimal("0.5")

  PERIODS = [
    [:d1,  "1D"],
    [:w1,  "1W"],
    [:m1,  "1M"],
    [:m3,  "3M"],
    [:mtd, "MTD"],
    [:qtd, "QTD"],
    [:ytd, "YTD"],
    [:y1,  "1Y"],
    [:inception, "Since inception"]
  ].freeze
  TRAILING = %i[d1 w1 m1 m3 y1].freeze # require a full prior-boundary point

  DayReturn = Struct.new(:date, :value, :external, :dividend, :daily_return, :daily_pnl, keyword_init: true)
  PeriodResult = Struct.new(:key, :label, :return_pct, :pnl, :available, keyword_init: true)
  Row = Struct.new(
    :scope, :label, :current_value, :invested, :deposits, :withdrawals,
    :dividends, :daily_return, :daily_pnl, :periods, :inception, :as_of,
    :final, :last_date,
    keyword_init: true
  )

  class << self
    def for_portfolio(portfolio, role: "all", as_of: Date.current)
      new(base_id: Currency.reporting_currency_id).row_for([portfolio], label: portfolio.name, scope: portfolio, role: role, as_of: as_of)
    end

    def combined(portfolios, role: "all", as_of: Date.current)
      new(base_id: Currency.reporting_currency_id).row_for(portfolios, label: "All portfolios", scope: :combined, role: role, as_of: as_of)
    end

    # Rows for each portfolio plus a combined row. Portfolios with no data are kept
    # (their periods render N/A). Used by the comparison pages.
    def table(portfolios, role: "all", as_of: Date.current)
      svc = new(base_id: Currency.reporting_currency_id)
      rows = portfolios.map { |p| svc.row_for([p], label: p.name, scope: p, role: role, as_of: as_of) }
      rows << svc.row_for(portfolios, label: "All portfolios", scope: :combined, role: role, as_of: as_of) if portfolios.size > 1
      rows
    end

    # Normalised (base 100) comparison series for the chart. Uses COMPOUNDED
    # cash-flow-adjusted returns (never raw values), so deposits/withdrawals never
    # move a curve. mode: "own" (each starts at 100 on its own first in-window date)
    # or "common" (all + benchmark start at 100 on the latest inception among the
    # selected set). Returns { common_start:, series: [{label, kind, points}] } where
    # each point is [iso_date, index, return_pct, value, pnl] (value/pnl nil for a
    # benchmark). benchmark: include each portfolio's benchmark index as a series.
    def normalized_series(portfolios, role: "all", from:, to: Date.current, mode: "own", benchmark: false)
      new(base_id: Currency.reporting_currency_id)
        .normalized_series(portfolios, role: role, from: from, to: to, mode: mode, benchmark: benchmark)
    end

    # Public period boundary dates (for aligning a benchmark to the same windows).
    def boundaries(as_of:, inception:)
      svc = new(base_id: nil)
      PERIODS.to_h { |k, _l| [k, svc.send(:period_boundary, k, as_of, inception)] }
    end
  end

  def initialize(base_id:)
    @base_id = base_id
  end

  def row_for(portfolios, label:, scope:, role:, as_of:)
    daily = daily_for(portfolios, role: role)
    daily = daily.select { |d| d.date <= as_of }
    if daily.empty?
      return Row.new(scope: scope, label: label, current_value: nil, invested: 0.to_d,
                     deposits: 0.to_d, withdrawals: 0.to_d, dividends: 0.to_d,
                     daily_return: nil, daily_pnl: nil,
                     periods: PERIODS.to_h { |k, l| [k, PeriodResult.new(key: k, label: l, return_pct: nil, pnl: nil, available: false)] },
                     inception: nil, as_of: as_of, final: true, last_date: nil)
    end

    last = daily.last
    inception = daily.first.date
    last_date = last.date
    # Final when the last data point is a stored EOD snapshot (or lies in the past);
    # Intraday only when today's value is not yet a recorded snapshot. Uses the
    # snapshot table as the session-status signal (no hardcoded market close).
    snap_final = PortfolioSnapshot.where(portfolio_id: portfolios.map(&:id), date: last_date).count >= portfolios.size
    final = last_date < Date.current || snap_final
    deposits = daily.sum { |d| d.external.positive? ? d.external : 0.to_d }
    withdrawals = daily.sum { |d| d.external.negative? ? -d.external : 0.to_d }
    dividends = daily.sum(&:dividend)
    invested = daily.sum(&:external)

    periods = PERIODS.to_h do |key, plabel|
      [key, period_result(daily, key, plabel, inception)]
    end

    Row.new(
      scope: scope, label: label,
      current_value: last.value, invested: invested,
      deposits: deposits, withdrawals: withdrawals, dividends: dividends,
      daily_return: last.daily_return, daily_pnl: last.daily_pnl,
      periods: periods, inception: inception, as_of: as_of,
      final: final, last_date: last_date
    )
  end

  # Daily return series for a scope (list of portfolios) + role.
  def daily_for(portfolios, role:)
    values, flows = value_and_flows(portfolios, role)
    build_daily(values, flows)
  end

  # Instance entry point for the comparison chart (see class method docs).
  def normalized_series(portfolios, role:, from:, to: Date.current, mode: "own", benchmark: false)
    dailies = portfolios.map { |p| [p, daily_for([p], role: role).select { |d| d.date <= to }] }

    start_on = nil
    common = nil
    if mode.to_s == "common"
      firsts = dailies.filter_map { |_p, dd| window_first_date(dd, from, to) }
      common = firsts.max
      start_on = common
    end

    series = []
    dailies.each do |p, dd|
      pts = normalize(dd, from: from, to: to, start_on: start_on)
      series << { label: p.name, kind: "portfolio", points: pts } if pts.present?
    end

    if benchmark
      benchmark_indices(portfolios).each do |mi|
        pts = normalize(benchmark_daily(mi), from: from, to: to, start_on: start_on)
        series << { label: "#{mi.code} · benchmark", kind: "benchmark", points: pts } if pts.present?
      end
    end

    { common_start: common&.iso8601, series: series }
  end

  # Base-100 normalised points over [from, to] using COMPOUNDED daily returns.
  # start_on forces the base date (common-start mode); otherwise the first in-window
  # day is the base. Each point: [iso, index, return_pct, value, cumulative_pnl].
  def normalize(daily, from:, to:, start_on: nil)
    window = daily.select { |d| d.date >= from && d.date <= to }
    window = window.select { |d| d.date >= start_on } if start_on
    return [] if window.size < 2

    idx = 100.to_d
    cum = 0.to_d
    first = window.first
    out = [normalized_point(first.date, idx, 0.to_d, first.value, cum)]
    window.drop(1).each do |d|
      idx *= (1 + (d.daily_return || 0.to_d))
      cum += (d.daily_pnl || 0.to_d)
      out << normalized_point(d.date, idx, idx - 100, d.value, cum)
    end
    out
  end

  private

  def normalized_point(date, idx, ret, value, pnl)
    [date.iso8601, idx.to_f.round(2), ret.to_f.round(2), value&.to_f&.round(2), pnl&.to_f&.round(2)]
  end

  def window_first_date(daily, from, to)
    d = daily.find { |x| x.date >= from && x.date <= to }
    d&.date
  end

  def benchmark_indices(portfolios)
    portfolios.filter_map(&:benchmark_market_index).uniq
  end

  # A benchmark index as a daily-return series (no external flows: price return IS
  # its time-weighted return). value = index level; pnl is N/A for an index.
  def benchmark_daily(market_index)
    prev = nil
    IndexPrice.where(market_index_id: market_index.id).order(:date).pluck(:date, :price).map do |(d, price)|
      lvl = price.to_d
      r = (prev && prev.nonzero?) ? (lvl / prev - 1) : nil
      prev = lvl
      DayReturn.new(date: d, value: lvl, external: 0.to_d, dividend: 0.to_d, daily_return: r, daily_pnl: nil)
    end
  end

  private

  def period_result(daily, key, label, inception)
    as_of = daily.last.date
    boundary = period_boundary(key, as_of, inception)
    if boundary.nil?
      return PeriodResult.new(key: key, label: label, return_pct: nil, pnl: nil, available: false)
    end

    # start reference = latest day on/before boundary; window = days after it.
    # Since-inception compounds the entire series (its first day has no prior day).
    start_idx = daily.rindex { |d| d.date <= boundary }
    if start_idx.nil?
      # No point at/before the boundary. Trailing periods (1D..1Y) then have
      # insufficient history => N/A. Calendar periods and since-inception fall back
      # to the whole available series (i.e. "YTD" becomes "since inception" for a
      # portfolio younger than the calendar boundary) rather than fabricating.
      return PeriodResult.new(key: key, label: label, return_pct: nil, pnl: nil, available: false) if TRAILING.include?(key)

      start_idx = -1
    end

    window = daily[(start_idx + 1)..] || []
    if window.empty?
      return PeriodResult.new(key: key, label: label, return_pct: 0.to_d, pnl: 0.to_d, available: true)
    end

    factor = 1.to_d
    pnl = 0.to_d
    window.each do |d|
      factor *= (1 + (d.daily_return || 0.to_d))
      pnl += (d.daily_pnl || 0.to_d)
    end

    PeriodResult.new(key: key, label: label, return_pct: (factor - 1) * 100, pnl: pnl, available: true)
  end

  # Returns the reference boundary date for a period, or nil if unavailable.
  def period_boundary(key, as_of, inception)
    b =
      case key
      when :d1  then as_of - 1
      when :w1  then as_of - 7
      when :m1  then as_of << 1
      when :m3  then as_of << 3
      when :y1  then as_of << 12
      when :mtd then as_of.beginning_of_month - 1
      when :qtd then as_of.beginning_of_quarter - 1
      when :ytd then as_of.beginning_of_year - 1
      when :inception then return inception - 1 # whole history
      end
    return b unless TRAILING.include?(key)

    # Trailing periods need a real point at/before the boundary within history.
    b >= inception ? b : nil
  end

  # Assemble the value + flow series for a scope, choosing stored snapshots for
  # role=all and reconstruction for role subsets.
  def value_and_flows(portfolios, role)
    if role.to_s == "all"
      values = merged_snapshot_values(portfolios)
      flows = PortfolioCashFlowService.call(portfolios.map(&:id), base_id: @base_id)
      # Fallback to reconstruction if snapshots are absent.
      return [values, flows] if values.present?
    end

    merged_reconstructed(portfolios, role)
  end

  # Sum stored snapshot total_values across portfolios, aligned by the union of
  # dates with carry-forward per portfolio.
  def merged_snapshot_values(portfolios)
    per = portfolios.map do |p|
      PortfolioSnapshot.where(portfolio_id: p.id).order(:date).pluck(:date, :total_value)
    end
    align_and_sum(per)
  end

  def merged_reconstructed(portfolios, role)
    per_values = []
    flows = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: 0.to_d, dividend: 0.to_d) }
    portfolios.each do |p|
      s = PortfolioValueSeriesService.call(p, role: role, base_id: @base_id)
      per_values << s.values
      s.flows.each do |d, day|
        flows[d].external += day.external
        flows[d].dividend += day.dividend
      end
    end
    [align_and_sum(per_values), flows]
  end

  # per = [ [[date, value], ...], ... ]. Union dates; each series carries its last
  # value forward; sum across series. => [[date, total], ...] ascending.
  def align_and_sum(per)
    per = per.reject(&:blank?)
    return [] if per.empty?

    all_dates = per.flat_map { |ser| ser.map(&:first) }.uniq.sort
    cursors = Array.new(per.size, 0)
    carried = Array.new(per.size, 0.to_d)

    all_dates.map do |d|
      total = 0.to_d
      per.each_with_index do |ser, i|
        while cursors[i] < ser.size && ser[cursors[i]][0] <= d
          carried[i] = ser[cursors[i]][1].to_d
          cursors[i] += 1
        end
        total += carried[i]
      end
      [d, total]
    end
  end

  # Modified Dietz daily returns over an aligned [[date, value], ...] series.
  def build_daily(values, flows)
    prev = nil
    values.map do |(d, v)|
      day = flows[d] || PortfolioCashFlowService::Day.new(external: 0.to_d, dividend: 0.to_d)
      f = day.external
      div = day.dividend
      if prev.nil?
        row = DayReturn.new(date: d, value: v.to_d, external: f, dividend: div, daily_return: nil, daily_pnl: nil)
      else
        start = prev.to_d
        pnl = v.to_d - start - f + div
        denom = start + (f * HALF)
        r = denom.zero? ? nil : (pnl / denom)
        row = DayReturn.new(date: d, value: v.to_d, external: f, dividend: div, daily_return: r, daily_pnl: pnl)
      end
      prev = v
      row
    end
  end
end
