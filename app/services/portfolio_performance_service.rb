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
#
# Benchmarks (EGX30, EGX33 Shariah — see MarketIndex.benchmarks) are handled as a
# SEPARATE, comparison-only overlay: a benchmark's daily series is its price return
# (no external flows), normalised and rebased to the SAME comparison start as the
# portfolios. Benchmarks NEVER enter a portfolio's value, "All portfolios",
# allocation, cash, flows, XIRR or any portfolio card (spec #13/#14).
#
# Two bases (basis: keyword, default :invested = everything described above):
#   :invested  Invested TWR  — holdings only. A sale is an outflow, so cash retained
#              after de-risking is NOT part of the measured capital.
#   :wealth    Wealth Return — holdings + retained portfolio cash (Managed Wealth),
#              same Modified Dietz + compounding engine. Buys/sells/dividends are
#              internal (they move value between holdings and cash); only
#              PortfolioCashFlow contributions/withdrawals/transfers are external. See
#              PortfolioWealthSeriesService. Unsupported histories render N/A.
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

  # cash: retained cash inside value (wealth basis only; nil for the invested basis).
  DayReturn = Struct.new(:date, :value, :external, :dividend, :daily_return, :daily_pnl, :cash, keyword_init: true)
  PeriodResult = Struct.new(:key, :label, :return_pct, :pnl, :available, keyword_init: true)
  # One calendar period (quarter / year / overall): opening balance (= previous period's
  # closing), net external money added(+)/withdrawn(-), gain, closing balance, and the
  # time-weighted return (flow-neutral, chained from the daily returns).
  CalendarPeriod = Struct.new(:label, :unit, :ends_on, :opening, :closing, :net_flow, :gain, :return_pct, :complete,
                              keyword_init: true)
  Row = Struct.new(
    :scope, :label, :current_value, :invested, :deposits, :withdrawals,
    :dividends, :daily_return, :daily_pnl, :periods, :inception, :as_of,
    :final, :last_date,
    :basis, :note, :cash, :cash_weight, # wealth basis extras (note = why N/A)
    keyword_init: true
  )

  class << self
    def for_portfolio(portfolio, role: "all", as_of: Date.current, basis: :invested)
      new(base_id: Currency.reporting_currency_id, basis: basis).row_for([portfolio], label: portfolio.name, scope: portfolio, role: role, as_of: as_of)
    end

    def combined(portfolios, role: "all", as_of: Date.current, basis: :invested)
      new(base_id: Currency.reporting_currency_id, basis: basis).row_for(portfolios, label: "All portfolios", scope: :combined, role: role, as_of: as_of)
    end

    # Rows for each portfolio plus a combined row. Portfolios with no data are kept
    # (their periods render N/A). Used by the comparison pages.
    def table(portfolios, role: "all", as_of: Date.current, basis: :invested)
      svc = new(base_id: Currency.reporting_currency_id, basis: basis)
      rows = portfolios.map { |p| svc.row_for([p], label: p.name, scope: p, role: role, as_of: as_of) }
      rows << svc.row_for(portfolios, label: "All portfolios", scope: :combined, role: role, as_of: as_of) if portfolios.size > 1
      rows
    end

    # Quarter / year / overall tables per portfolio plus a combined entry (when >1 selected).
    # => [{ label:, scope:, quarters: [CalendarPeriod], years: [CalendarPeriod], overall: CalendarPeriod|nil, note: }]
    def calendar_table(portfolios, role: "all", basis: :invested)
      svc = new(base_id: Currency.reporting_currency_id, basis: basis)
      entries = portfolios.map { |p| svc.calendar_entry([p], label: p.name, scope: p, role: role) }
      entries << svc.calendar_entry(portfolios, label: "All portfolios", scope: :combined, role: role) if portfolios.size > 1
      entries
    end

    # Comparison-only rows for the market benchmarks (EGX30, EGX33 Shariah). Each
    # row's scope is the MarketIndex itself, so it is trivially excluded from every
    # portfolio-only card and aggregation. Empty when no benchmarks are configured.
    def benchmark_rows(as_of: Date.current, indices: nil)
      list = indices || MarketIndex.benchmarks.to_a
      svc = new(base_id: Currency.reporting_currency_id)
      list.map { |mi| svc.benchmark_row(mi, as_of: as_of) }
    end

    # A benchmark's cash-flow-free daily-return series (price return IS its TWR).
    # Consumed by PortfolioRiskService for benchmark risk metrics.
    def benchmark_daily_series(market_index)
      new(base_id: nil).benchmark_daily(market_index)
    end

    # Normalised (base 100) comparison series for the chart. Uses COMPOUNDED
    # cash-flow-adjusted returns (never raw values), so deposits/withdrawals never
    # move a curve. mode: "own" (each starts at 100 on its own first in-window date)
    # or "common" (all + benchmarks start at 100 on the latest inception among the
    # selected set). Returns { common_start:, series: [{label, kind, points}] } where
    # each point is [iso_date, index, return_pct, value, pnl] (value/pnl nil for a
    # benchmark). benchmark: append the market benchmark index series.
    # basis: :wealth switches the portfolio curves to Managed Wealth (holdings + retained
    # cash); benchmarks are unchanged. combined: true adds an "All portfolios" curve
    # (internal transfers net to zero) when more than one portfolio is selected. Wealth
    # points carry a 6th element: cash weight % of that day's value.
    def normalized_series(portfolios, role: "all", from:, to: Date.current, mode: "own", benchmark: false,
                          basis: :invested, combined: false)
      new(base_id: Currency.reporting_currency_id, basis: basis)
        .normalized_series(portfolios, role: role, from: from, to: to, mode: mode, benchmark: benchmark, combined: combined)
    end

    # Raw cash-flow-adjusted daily return series for a scope (list of portfolios) +
    # role. Consumed by PortfolioRiskService so risk metrics use exactly the same
    # returns as the rest of the engine (consolidated = one series when many).
    def daily_series(portfolios, role: "all", basis: :invested)
      new(base_id: Currency.reporting_currency_id, basis: basis).daily_for(portfolios, role: role)
    end

    # Public period boundary dates (for aligning a benchmark to the same windows).
    def boundaries(as_of:, inception:)
      svc = new(base_id: nil)
      PERIODS.to_h { |k, _l| [k, svc.send(:period_boundary, k, as_of, inception)] }
    end
  end

  def initialize(base_id:, basis: :invested)
    @base_id = base_id
    @basis = basis.to_s == "wealth" ? :wealth : :invested
    @wealth_cache = {}
  end

  def wealth?
    @basis == :wealth
  end

  def calendar_entry(portfolios, label:, scope:, role:)
    daily = daily_for(portfolios, role: role)
    note = daily.empty? ? wealth_unavailable_note(portfolios, role) : (wealth? && @wealth_through ? "valid through #{@wealth_through.iso8601}" : nil)
    { label: label, scope: scope, quarters: calendar_periods(daily, :quarter), years: calendar_periods(daily, :year),
      overall: overall_period(daily), note: note }
  end

  # Periods tile the history: each opens at the previous period's closing value, so
  # "Q2 opens at Q1's close". Period return = chained daily returns (external money added
  # or withdrawn is neutralised), NOT closing/opening - 1.
  def calendar_periods(daily, unit)
    return [] if daily.size < 2

    prev_close = daily.first.value
    last_date = daily.last.date
    daily.drop(1).group_by { |d| calendar_key(d.date, unit) }.sort_by(&:first).map do |key, rows|
      period = build_calendar_period(rows, prev_close, unit, key, last_date)
      prev_close = period.closing
      period
    end
  end

  def overall_period(daily)
    return nil if daily.size < 2

    p = build_calendar_period(daily.drop(1), daily.first.value, :overall, nil, daily.last.date)
    p.label = "Overall (#{daily.first.date.iso8601} → #{daily.last.date.iso8601})"
    p.complete = true
    p
  end

  def row_for(portfolios, label:, scope:, role:, as_of:)
    daily = daily_for(portfolios, role: role)
    daily = daily.select { |d| d.date <= as_of }
    if daily.empty?
      return Row.new(scope: scope, label: label, current_value: nil, invested: 0.to_d,
                     deposits: 0.to_d, withdrawals: 0.to_d, dividends: 0.to_d,
                     daily_return: nil, daily_pnl: nil,
                     periods: PERIODS.to_h { |k, l| [k, PeriodResult.new(key: k, label: l, return_pct: nil, pnl: nil, available: false)] },
                     inception: nil, as_of: as_of, final: true, last_date: nil,
                     basis: @basis, note: wealth_unavailable_note(portfolios, role))
    end

    last = daily.last
    inception = daily.first.date
    last_date = last.date
    # Final when the last data point is a stored EOD snapshot (or lies in the past);
    # Intraday only when today's value is not yet a recorded snapshot. Uses the
    # snapshot table as the session-status signal (no hardcoded market close).
    final = last_date < Date.current || snapshots_final?(portfolios, last_date)
    deposits = daily.sum { |d| d.external.positive? ? d.external : 0.to_d }
    withdrawals = daily.sum { |d| d.external.negative? ? -d.external : 0.to_d }
    dividends = daily.sum(&:dividend)
    invested = daily.sum(&:external)

    periods = PERIODS.to_h do |key, plabel|
      [key, period_result(daily, key, plabel, inception)]
    end

    note = nil
    if wealth? && @wealth_through
      # Only history up to @wealth_through is trustworthy: everything anchored to "today"
      # is N/A; since-inception is shown through that date.
      periods = periods.to_h do |k, pr|
        k == :inception ? [k, pr] : [k, PeriodResult.new(key: k, label: pr.label, return_pct: nil, pnl: nil, available: false)]
      end
      note = "cash history is reliable only through #{@wealth_through.iso8601}; since-inception is measured through that date, other periods are N/A"
    end

    Row.new(
      scope: scope, label: label,
      current_value: last.value, invested: invested,
      deposits: deposits, withdrawals: withdrawals, dividends: dividends,
      daily_return: last.daily_return, daily_pnl: last.daily_pnl,
      periods: periods, inception: inception, as_of: as_of,
      final: final, last_date: last_date,
      basis: @basis, cash: last.cash, cash_weight: cash_weight(last), note: note
    )
  end

  # A benchmark index as a comparison-only Row (scope = the MarketIndex). Period
  # returns compound the index's own daily returns — identical to its simple price
  # return over each window, and directly comparable to a portfolio's TWR. No
  # invested/flows/dividends (an index has none); current_value = latest level.
  def benchmark_row(market_index, as_of:)
    daily = benchmark_daily(market_index).select { |d| d.date <= as_of }
    if daily.empty?
      return Row.new(scope: market_index, label: market_index.code, current_value: nil,
                     invested: 0.to_d, deposits: 0.to_d, withdrawals: 0.to_d, dividends: 0.to_d,
                     daily_return: nil, daily_pnl: nil,
                     periods: PERIODS.to_h { |k, l| [k, PeriodResult.new(key: k, label: l, return_pct: nil, pnl: nil, available: false)] },
                     inception: nil, as_of: as_of, final: true, last_date: nil)
    end

    last = daily.last
    inception = daily.first.date
    periods = PERIODS.to_h { |key, plabel| [key, period_result(daily, key, plabel, inception)] }

    Row.new(
      scope: market_index, label: market_index.code,
      current_value: last.value, invested: 0.to_d,
      deposits: 0.to_d, withdrawals: 0.to_d, dividends: 0.to_d,
      daily_return: last.daily_return, daily_pnl: nil,
      periods: periods, inception: inception, as_of: as_of,
      final: last.date < Date.current, last_date: last.date
    )
  end

  # Daily return series for a scope (list of portfolios) + role.
  def daily_for(portfolios, role:)
    if wealth?
      values, flows, cash = wealth_values_flows_cash(portfolios, role)
      return build_daily(values, flows, cash)
    end

    values, flows = value_and_flows(portfolios, role)
    build_daily(values, flows)
  end

  # Instance entry point for the comparison chart (see class method docs).
  def normalized_series(portfolios, role:, from:, to: Date.current, mode: "own", benchmark: false, combined: false)
    dailies = portfolios.map { |p| [p, daily_for([p], role: role).select { |d| d.date <= to }] }

    start_on = nil
    common = nil
    if mode.to_s == "common"
      firsts = dailies.filter_map { |_p, dd| window_first_date(dd, from, to) }
      # The common start must be a date every SELECTED PORTFOLIO can be rebased on
      # (the latest portfolio inception in-window). Benchmarks, being reference
      # series, are rebased onto that same date — they never move it (spec #5).
      common = firsts.max
      start_on = common
    end

    series = []
    dailies.each do |p, dd|
      pts = normalize(dd, from: from, to: to, start_on: start_on)
      series << { label: p.name, kind: "portfolio", points: pts } if pts.present?
    end

    if combined && portfolios.size > 1
      # Internal portfolio-to-portfolio moves cancel inside the combined series. It is
      # rebased on the same start as the others and never moves the common start.
      all_daily = daily_for(portfolios, role: role).select { |d| d.date <= to }
      pts = normalize(all_daily, from: from, to: to, start_on: start_on)
      series << { label: "All portfolios", kind: "portfolio", points: pts } if pts.present?
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
    out = [normalized_point(first.date, idx, 0.to_d, first.value, cum, cash_weight(first))]
    window.drop(1).each do |d|
      idx *= (1 + (d.daily_return || 0.to_d))
      cum += (d.daily_pnl || 0.to_d)
      out << normalized_point(d.date, idx, idx - 100, d.value, cum, cash_weight(d))
    end
    out
  end

  # A benchmark index as a daily-return series (no external flows: price return IS
  # its time-weighted return). value = index level; pnl is N/A for an index. Uses
  # actual trading-day observations only — no interpolation or fabricated closes
  # (spec #6); carry-forward for non-trading dates happens at read time in
  # IndexReturnService, not here.
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

  # The invested basis keeps the original 5-element point; the wealth basis appends the
  # cash weight (% of value held as retained cash) as a 6th element.
  def normalized_point(date, idx, ret, value, pnl, cash_pct = nil)
    pt = [date.iso8601, idx.to_f.round(2), ret.to_f.round(2), value&.to_f&.round(2), pnl&.to_f&.round(2)]
    pt << cash_pct&.to_f&.round(2) if wealth?
    pt
  end

  # Retained cash as a % of that day's Managed Wealth (wealth basis only).
  def cash_weight(day)
    return nil unless wealth? && day.cash && day.value&.positive?

    day.cash / day.value * 100
  end

  def snapshots_final?(portfolios, last_date)
    PortfolioSnapshot.where(portfolio_id: portfolios.map(&:id), date: last_date).count >= portfolios.size
  end

  def calendar_key(date, unit)
    unit == :year ? [date.year, 0] : [date.year, ((date.month - 1) / 3) + 1]
  end

  def calendar_end(key, unit)
    year, q = key
    unit == :year ? Date.new(year, 12, 31) : Date.new(year, q * 3, -1)
  end

  def build_calendar_period(rows, opening, unit, key, last_date)
    factor = 1.to_d
    flow = 0.to_d
    gain = 0.to_d
    rows.each do |r|
      factor *= (1 + (r.daily_return || 0.to_d))
      flow += r.external
      gain += (r.daily_pnl || 0.to_d)
    end
    ends_on = key ? calendar_end(key, unit) : last_date
    label = key ? (unit == :year ? key[0].to_s : "#{key[0]} Q#{key[1]}") : "Overall"
    CalendarPeriod.new(label: label, unit: unit, ends_on: ends_on, opening: opening, closing: rows.last.value,
                       net_flow: flow, gain: gain, return_pct: (factor - 1) * 100, complete: last_date >= ends_on)
  end

  # ---- Wealth basis -----------------------------------------------------------
  # Per-portfolio Managed Wealth series (memoised: a portfolio is built once even
  # though it feeds its own row, the combined row and the chart).
  def wealth_series_for(portfolio, role)
    @wealth_cache[[portfolio.id, role.to_s]] ||=
      PortfolioWealthSeriesService.call(portfolio, role: role, base_id: @base_id)
  end

  # [values, flows, cash] for a scope. All-or-nothing: if ANY selected portfolio's
  # wealth cannot be reconstructed, the scope is N/A rather than silently omitting
  # that portfolio's capital.
  def wealth_values_flows_cash(portfolios, role)
    @wealth_through = nil
    series = portfolios.map { |p| wealth_series_for(p, role) }
    return [[], {}, {}] if series.empty? || series.any? { |s| !s.available? }

    flows = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: 0.to_d, dividend: 0.to_d) }
    series.each do |s|
      s.flows.each do |d, day|
        flows[d].external += day.external
        flows[d].dividend += day.dividend
      end
    end
    values = align_and_sum(series.map(&:values))
    cash = align_and_sum(series.map(&:cash_values)).to_h
    # If any portfolio's cash history is only reliable up to a date, the combined series
    # ends there too (carrying a stale value forward would be fabricated).
    @wealth_through = series.filter_map(&:through).min
    if @wealth_through
      values = values.select { |d, _v| d <= @wealth_through }
      cash = cash.select { |d, _c| d <= @wealth_through }
    end
    [values, flows, cash]
  end

  # Why a wealth row is N/A (shown as a tooltip/note), or nil on the invested basis.
  def wealth_unavailable_note(portfolios, role)
    return nil unless wealth?

    parts = portfolios.filter_map do |p|
      s = wealth_series_for(p, role)
      next if s.available?

      "#{p.name}: #{PortfolioWealthSeriesService.reason_text(s)}"
    end
    parts.presence&.join("; ")
  end

  def window_first_date(daily, from, to)
    d = daily.find { |x| x.date >= from && x.date <= to }
    d&.date
  end

  # The market benchmarks to overlay on the chart: the globally-flagged EGX30 /
  # EGX33 Shariah set, NOT each portfolio's individually-assigned tracking index.
  # "Show benchmarks" always shows both, independent of portfolio selection (#8).
  def benchmark_indices(_portfolios)
    MarketIndex.benchmarks.to_a
  end

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
    # Reconstruct the value + flow series from transactions and prices for every
    # role (including "all"). The reconstruction values each holding at its own
    # transaction price on trade days, so a buy/sell moves value by exactly its
    # cash amount and nets to zero in Modified Dietz — robust regardless of whether
    # a market snapshot was recorded that day. (Stored on-visit snapshots were
    # sparse and mis-timed against trades, which showed purchases as profit.)
    values, flows = merged_reconstructed(portfolios, role)
    return [values, flows] if values.present?

    # Last-resort fallback: stored snapshots (holdings market value) if there is no
    # reconstructable history yet.
    if role.to_s == "all"
      snaps = merged_snapshot_values(portfolios)
      return [snaps, PortfolioCashFlowService.call(portfolios.map(&:id), base_id: @base_id)] if snaps.present?
    end

    [values, flows]
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
  def build_daily(values, flows, cash = nil)
    # Bucket every external flow into the window ending at each snapshot date, so a
    # buy/sell dated BETWEEN snapshots still offsets its holdings-value jump. A plain
    # flows[d] lookup would drop flows on non-snapshot days and mis-count a purchase
    # as investment return. Both series are ascending, so one cursor visits each
    # flow exactly once.
    flow_dates = flows.keys.sort
    fi = 0
    prev = nil
    values.map do |(d, v)|
      f = 0.to_d
      div = 0.to_d
      while fi < flow_dates.size && flow_dates[fi] <= d
        day = flows[flow_dates[fi]]
        f += day.external
        div += day.dividend
        fi += 1
      end

      if prev.nil?
        row = DayReturn.new(date: d, value: v.to_d, external: f, dividend: div, daily_return: nil, daily_pnl: nil, cash: cash&.[](d))
      else
        start = prev.to_d
        pnl = v.to_d - start - f + div
        denom = start + (f * HALF)
        r = denom.zero? ? nil : (pnl / denom)
        row = DayReturn.new(date: d, value: v.to_d, external: f, dividend: div, daily_return: r, daily_pnl: pnl, cash: cash&.[](d))
      end
      prev = v
      row
    end
  end
end
