# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Estimate aggregation + freshness logic (spec acceptance tests #30 A–E).
# Pure-method tests: the service instance is allocated without hitting the DB.
class AssetEstimateSummaryServiceTest < ActiveSupport::TestCase
  def svc(current_price: nil)
    s = AssetEstimateSummaryService.allocate
    s.instance_variable_set(:@current_price, current_price)
    s
  end

  def bd(x) = BigDecimal(x.to_s)

  # A) three independent fundamentals 120,130,150 => min/median/max
  test "A: min, median, max over the estimate set" do
    targets = [bd(120), bd(130), bd(150)].sort
    assert_equal bd(120), targets.first
    assert_equal bd(130), svc.send(:median, targets)
    assert_equal bd(150), targets.last
  end

  # B) current 100 => median upside 30%, min 20%, max 50%
  test "B: expected upside vs current price" do
    s = svc(current_price: bd(100))
    assert_equal bd(20), s.send(:upside, bd(120))
    assert_equal bd(30), s.send(:upside, bd(130))
    assert_equal bd(50), s.send(:upside, bd(150))
  end

  # C) MarketScreener + Investing sharing a source_family => 1 independent, not 2
  test "C: duplicate source families collapse to one representative" do
    rows = [
      OpenStruct.new(family_key: "consensus_x", preferred: false, estimate_date: Date.new(2026, 3, 1), confidence_score: nil, created_at: Time.utc(2026, 3, 1)),
      OpenStruct.new(family_key: "consensus_x", preferred: false, estimate_date: Date.new(2026, 1, 1), confidence_score: nil, created_at: Time.utc(2026, 1, 1))
    ]
    reps = rows.group_by(&:family_key).map { |_f, fam| svc.send(:representative_of, fam) }
    assert_equal 1, reps.size
    assert_equal Date.new(2026, 3, 1), reps.first.estimate_date, "keeps the most recent"
  end

  # D) technical (1m) and fundamental (12m) must not be averaged together
  test "D: different estimate types/horizons group separately" do
    tech = AssetEstimate.new(estimate_type: "technical", horizon_type: "short_term")
    fund = AssetEstimate.new(estimate_type: "fundamental", horizon_type: "twelve_month")
    groups = [tech, fund].group_by { |e| [e.section, e.horizon_type] }
    assert_equal 2, groups.size
    assert_equal :technical, tech.section
    assert_equal :fundamental, fund.section
  end

  # E) freshness thresholds differ by type; stale detection
  test "E: freshness respects per-type thresholds" do
    today = Date.new(2026, 6, 1)
    fresh_tech = AssetEstimate.new(estimate_type: "technical", estimate_date: today - 20)
    stale_tech = AssetEstimate.new(estimate_type: "technical", estimate_date: today - 90)
    fresh_fund = AssetEstimate.new(estimate_type: "fundamental", estimate_date: today - 90)
    assert_equal :fresh, fresh_tech.freshness(today)
    assert_equal :stale, stale_tech.freshness(today)
    assert stale_tech.stale?(today)
    assert_equal :fresh, fresh_fund.freshness(today), "90 days is still fresh for a fundamental"
  end

  test "nearest target picks the estimate closest to current price" do
    s = svc(current_price: bd(126))
    assert_equal bd(129), s.send(:nearest_to_current, [bd(129), bd(134), bd(140)])
  end

  test "family_key falls back to source_name when no family set" do
    e = AssetEstimate.new(source_name: "Independent analyst", source_family: nil)
    assert_equal "name:Independent analyst", e.family_key
  end

  test "even-count median averages the two middle values" do
    assert_equal bd(135), svc.send(:median, [bd(120), bd(130), bd(140), bd(150)])
  end
end
