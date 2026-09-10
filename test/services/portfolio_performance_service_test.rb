# frozen_string_literal: true

require "test_helper"

# Pure unit tests for the performance math (spec acceptance tests #29 A–F).
# These exercise the Modified Dietz + compounding logic directly, no DB needed.
class PortfolioPerformanceServiceTest < ActiveSupport::TestCase
  DayReturn = PortfolioPerformanceService::DayReturn
  def setup
    @svc = PortfolioPerformanceService.new(base_id: 1)
  end

  def bd(x) = BigDecimal(x.to_s)
  def d(s) = Date.parse(s)

  def flows(hash = {})
    f = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: bd(0), dividend: bd(0)) }
    hash.each { |k, (ext, div)| f[k] = PortfolioCashFlowService::Day.new(external: bd(ext), dividend: bd(div || 0)) }
    f
  end

  # A) 100,000 -> 101,000, no deposit => +1%
  test "A: pure appreciation gives the raw return" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(101_000)]]
    daily = @svc.send(:build_daily, vals, flows)
    assert_equal bd(1), (daily.last.daily_return * 100).round(6)
  end

  # B) deposit(=buy) 20,000, end 120,000, no market gain => ~0%
  test "B: a contribution is not investment return" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(120_000)]]
    daily = @svc.send(:build_daily, vals, flows(d("2026-01-02") => [20_000, 0]))
    assert_equal bd(0), daily.last.daily_return
    assert_equal bd(0), daily.last.daily_pnl
  end

  # C) start 100k, +20k, end 121k => gain is 1,000 (investment), not 21,000
  test "C: return reflects investment gain only, not added capital" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(121_000)]]
    daily = @svc.send(:build_daily, vals, flows(d("2026-01-02") => [20_000, 0]))
    assert_equal bd(1_000), daily.last.daily_pnl
    assert_equal bd("0.9091"), (daily.last.daily_return * 100).round(4)
  end

  # D) daily +1% then +2% compounds to 3.02%, not 3.00%
  test "D: period return compounds daily returns" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(101_000)], [d("2026-01-03"), bd(103_020)]]
    daily = @svc.send(:build_daily, vals, flows)
    res = @svc.send(:period_result, daily, :inception, "Since inception", daily.first.date)
    assert_equal bd("3.02"), res.return_pct.round(6)
    refute_equal bd(3), res.return_pct
  end

  # E) transfer 10k A->B (sell in A + buy in B): combined value + flows net out
  test "E: internal portfolio-to-portfolio move nets to zero combined" do
    a = [[d("2026-01-01"), bd(50_000)], [d("2026-01-02"), bd(40_000)]]
    b = [[d("2026-01-01"), bd(30_000)], [d("2026-01-02"), bd(40_000)]]
    combined = @svc.send(:align_and_sum, [a, b])
    assert_equal bd(80_000), combined[0][1]
    assert_equal bd(80_000), combined[1][1]
    # A external -10,000 + B external +10,000 = 0 combined => flat value => 0% return
    daily = @svc.send(:build_daily, combined, flows)
    assert_equal bd(0), daily.last.daily_return
  end

  # F) trailing period without enough history => N/A, never fabricated
  test "F: insufficient history yields N/A, not a fabricated number" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(101_000)]]
    daily = @svc.send(:build_daily, vals, flows)
    res = @svc.send(:period_result, daily, :y1, "1Y", daily.first.date)
    assert_not res.available
    assert_nil res.return_pct
  end

  # §10 withdrawal must not create a negative return
  test "withdrawal is not a negative return" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(80_000)]]
    daily = @svc.send(:build_daily, vals, flows(d("2026-01-02") => [-20_000, 0]))
    assert_equal bd(0), daily.last.daily_return
    assert_equal bd(0), daily.last.daily_pnl
  end

  # §23 normalization is cash-flow neutral: a deposit day does not move the index
  test "normalized index ignores deposits, tracks only investment return" do
    daily = @svc.send(:build_daily,
      [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(150_000)], [d("2026-01-03"), bd(165_000)]],
      flows(d("2026-01-02") => [50_000, 0]))
    pts = @svc.send(:normalize, daily, from: d("2026-01-01"), to: d("2026-01-03"))
    assert_equal 100.0, pts[0][1]
    assert_equal 100.0, pts[1][1], "deposit day stays at 100"
    assert_equal 110.0, pts[2][1], "+10% investment gain shows as 110"
    assert_equal 5, pts[0].size, "rich point [date, index, return%, value, pnl]"
  end

  # §21/§22 common-start: latest inception among the selected set is the base date
  test "common-start normalization rebases all series to the same date" do
    a = [DayReturn.new(date: d("2026-01-01"), value: bd(100), external: bd(0), dividend: bd(0), daily_return: nil, daily_pnl: nil),
         DayReturn.new(date: d("2026-01-10"), value: bd(110), external: bd(0), dividend: bd(0), daily_return: bd("0.10"), daily_pnl: bd(10))]
    b = [DayReturn.new(date: d("2026-01-10"), value: bd(50), external: bd(0), dividend: bd(0), daily_return: nil, daily_pnl: nil),
         DayReturn.new(date: d("2026-01-11"), value: bd(55), external: bd(0), dividend: bd(0), daily_return: bd("0.10"), daily_pnl: bd(5))]
    fa = @svc.send(:window_first_date, a, d("2026-01-01"), d("2026-01-31"))
    fb = @svc.send(:window_first_date, b, d("2026-01-01"), d("2026-01-31"))
    common = [fa, fb].max
    assert_equal d("2026-01-10"), common
    pa = @svc.send(:normalize, a, from: d("2026-01-01"), to: d("2026-01-31"), start_on: common)
    pb = @svc.send(:normalize, b, from: d("2026-01-01"), to: d("2026-01-31"), start_on: common)
    assert_equal "2026-01-10", pa.first[0]
    assert_equal 100.0, pa.first[1]
    assert_equal "2026-01-10", pb.first[0]
    assert_equal 100.0, pb.first[1]
  end

  test "align_and_sum carries each series forward across gaps" do
    x = [[d("2026-01-01"), bd(100)], [d("2026-01-03"), bd(110)]]
    y = [[d("2026-01-02"), bd(50)]]
    merged = @svc.send(:align_and_sum, [x, y])
    assert_equal bd(160), merged.last[1] # 110 + 50 carried forward
  end

  test "normalize rebases the series to 100" do
    vals = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(101_000)], [d("2026-01-03"), bd(103_020)]]
    daily = @svc.send(:build_daily, vals, flows)
    pts = @svc.send(:normalize, daily, from: d("2026-01-01"), to: d("2026-01-03"))
    assert_equal 100.0, pts.first[1]
    assert_equal 103.02, pts.last[1]
  end
end
