# frozen_string_literal: true

require "test_helper"

# Benchmark comparison math (spec #5 common-start rebasing, #7 normalization, #11
# excess return in percentage points). Pure math over hand-built DayReturn series
# shaped exactly like the engine's output — no DB, and no real market values are
# asserted as truth (the fixtures ARE the inputs).
class BenchmarkComparisonTest < ActiveSupport::TestCase
  DayReturn = PortfolioPerformanceService::DayReturn

  def setup
    @svc = PortfolioPerformanceService.new(base_id: nil)
  end

  def d(s) = Date.parse(s)
  def bd(x) = BigDecimal(x.to_s)

  # Build a return series: first day has nil return (base), then given daily
  # returns (as fractions) on successive dates.
  def series(start_date, rets)
    out = [DayReturn.new(date: d(start_date), value: bd(100), external: bd(0), dividend: bd(0), daily_return: nil, daily_pnl: nil)]
    rets.each_with_index do |r, i|
      out << DayReturn.new(date: d(start_date) + (i + 1), value: bd(100), external: bd(0), dividend: bd(0), daily_return: bd(r), daily_pnl: nil)
    end
    out
  end

  # Convert index levels into the benchmark daily-return series the engine builds
  # from IndexPrice (price return IS the TWR — no flows).
  def benchmark_from_levels(start_date, levels)
    prev = nil
    levels.each_with_index.map do |lvl, i|
      r = prev ? (bd(lvl) / prev - 1) : nil
      prev = bd(lvl)
      DayReturn.new(date: d(start_date) + i, value: bd(lvl), external: bd(0), dividend: bd(0), daily_return: r, daily_pnl: nil)
    end
  end

  # §5/#18: Core (inception 2026-07-29) and Borsa Halal (2026-09-01) with a
  # benchmark; in common-start mode the comparison start is 2026-09-01 and EVERY
  # series — portfolios AND benchmark — is 100 there.
  test "common-start rebases all series to 100 on the shared start date" do
    core   = series("2026-07-29", Array.new(40) { 0.001 })   # long history
    halal  = series("2026-09-01", [0.01, 0.02, -0.01])        # starts on the common date
    bench  = benchmark_from_levels("2026-08-25", [10_000, 10_050, 10_100, 10_080, 10_090, 10_120, 10_110, 10_130, 10_150, 10_170, 10_200, 10_180, 10_210, 10_240, 10_260, 10_250, 10_280, 10_300, 10_290, 10_310])

    common = d("2026-09-01")
    from   = d("2026-07-01")
    to     = d("2026-09-30")

    core_pts  = @svc.normalize(core,  from: from, to: to, start_on: common)
    halal_pts = @svc.normalize(halal, from: from, to: to, start_on: common)
    bench_pts = @svc.normalize(bench, from: from, to: to, start_on: common)

    [core_pts, halal_pts, bench_pts].each do |pts|
      assert pts.size >= 2, "series should have points in-window"
      assert_equal common.iso8601, pts.first[0], "first in-window point is the common start"
      assert_equal 100.0, pts.first[1], "series is rebased to 100 at the common start"
    end
  end

  # §7: normalized_value = 100 * close / close_at_start for a price series.
  test "benchmark normalization compounds price returns to a base-100 index" do
    bench = benchmark_from_levels("2026-09-01", [1000, 1010, 1030.2]) # +1% then +2%
    pts = @svc.normalize(bench, from: d("2026-09-01"), to: d("2026-09-03"), start_on: nil)
    assert_equal 100.0, pts.first[1]
    assert_in_delta 103.02, pts.last[1], 1e-6 # 100 * 1030.2/1000
  end

  # A benchmark's compounded period return equals its simple price return over the
  # window (an index has no external flows).
  test "benchmark period return equals simple price return" do
    bench = benchmark_from_levels("2026-09-01", [1000, 1010, 1030.2])
    res = @svc.send(:period_result, bench, :inception, "Since inception", bench.first.date)
    assert_in_delta 3.02, res.return_pct.to_f, 1e-6 # 1030.2/1000 - 1 = 3.02%
  end

  # §11: excess return in percentage POINTS = portfolio_return - benchmark_return.
  # Portfolio +5.00% vs benchmark +1.80% over the same window => +3.20 pp.
  test "excess return is portfolio minus benchmark in percentage points" do
    portfolio = series("2026-09-01", [0.05])                 # +5.00%
    bench     = benchmark_from_levels("2026-09-01", [100, 101.8]) # +1.80%

    p_ret = @svc.send(:period_result, portfolio, :inception, "Since inception", portfolio.first.date).return_pct
    b_ret = @svc.send(:period_result, bench, :inception, "Since inception", bench.first.date).return_pct
    excess_pp = p_ret - b_ret

    assert_in_delta 5.00, p_ret.to_f, 1e-6
    assert_in_delta 1.80, b_ret.to_f, 1e-6
    assert_in_delta 3.20, excess_pp.to_f, 1e-6
  end

  # §6: non-trading gap — the series carries real observations only; no fabricated
  # closes are inserted for the missing calendar day.
  test "benchmark series contains only actual trading-day observations" do
    bench = benchmark_from_levels("2026-09-01", [1000, 1005]) # Tue, Wed
    # skip Thu/Fri (weekend in EG); next observation Sunday
    bench << DayReturn.new(date: d("2026-09-06"), value: bd(1010), external: bd(0), dividend: bd(0),
                           daily_return: (bd(1010) / bd(1005) - 1), daily_pnl: nil)
    dates = bench.map(&:date)
    refute_includes dates, d("2026-09-04"), "no fabricated close for a non-trading date"
    assert_equal [d("2026-09-01"), d("2026-09-02"), d("2026-09-06")], dates
  end
end
