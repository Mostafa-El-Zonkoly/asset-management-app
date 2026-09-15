# frozen_string_literal: true

require "test_helper"

# TWR semantics acceptance tests (spec #19–#23). Proves the existing performance
# engine is a true Time-Weighted Return: external cash flows are neutralized and
# daily returns are geometrically chained.
#
# Mapping to THIS app's model: a portfolio IS its holdings. Money enters a sleeve
# by BUYING (an external contribution) and leaves by SELLING (an external
# withdrawal); both are recorded as external flows and valued at the trade cash
# amount, so they move value without creating return. Dividends are internal.
class TwrSemanticsTest < ActiveSupport::TestCase
  def setup
    @svc = PortfolioPerformanceService.new(base_id: 1)
  end

  def bd(x) = BigDecimal(x.to_s)
  def d(s) = Date.parse(s)

  # external is + on money IN (buy), - on money OUT (sell).
  def flows(hash = {})
    f = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: bd(0), dividend: bd(0)) }
    hash.each { |k, (ext, div)| f[k] = PortfolioCashFlowService::Day.new(external: bd(ext), dividend: bd(div || 0)) }
    f
  end

  def inception_twr(values, flows_hash)
    daily = @svc.send(:build_daily, values, flows_hash)
    @svc.send(:period_result, daily, :inception, "Since inception", daily.first.date).return_pct
  end

  # §19 — CONTRIBUTION. +10% then a 50,000 contribution (a buy) with no further
  # gain => +10.00%, NOT +60%.
  test "a contribution (buy) is not investment return" do
    values = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(110_000)], [d("2026-01-03"), bd(160_000)]]
    twr = inception_twr(values, flows(d("2026-01-03") => [50_000, 0]))
    assert_equal bd("10"), twr.round(6)
  end

  # §20 — WITHDRAWAL. +10% then a 50,000 withdrawal (a sell) => +10.00%, NOT -40%.
  test "a withdrawal (sell) is not investment loss" do
    values = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(110_000)], [d("2026-01-03"), bd(60_000)]]
    twr = inception_twr(values, flows(d("2026-01-03") => [-50_000, 0]))
    assert_equal bd("10"), twr.round(6)
  end

  # §21 — CHAINING. +10% then +5% compounds to +15.50%, never 15%.
  test "period TWR geometrically chains sub-period returns" do
    values = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(110_000)], [d("2026-01-03"), bd(115_500)]]
    twr = inception_twr(values, flows)
    assert_equal bd("15.5"), twr.round(6)
    refute_equal bd("15"), twr.round(6)
  end

  # §22 — INTERNAL TRANSFER. Core -> Ramble 10,000, no market move: each sleeve and
  # the Master aggregate are all 0.00%.
  test "an internal portfolio-to-portfolio transfer creates no return" do
    core = inception_twr(
      [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(90_000)]],
      flows(d("2026-01-02") => [-10_000, 0]) # sell/outflow
    )
    ramble = inception_twr(
      [[d("2026-01-01"), bd(50_000)], [d("2026-01-02"), bd(60_000)]],
      flows(d("2026-01-02") => [10_000, 0]) # buy/inflow
    )
    # Master: aggregate holdings unchanged (150k -> 150k), flows net to zero.
    master = inception_twr(
      [[d("2026-01-01"), bd(150_000)], [d("2026-01-02"), bd(150_000)]],
      flows(d("2026-01-02") => [0, 0])
    )
    assert_equal bd("0"), core.round(6)
    assert_equal bd("0"), ramble.round(6)
    assert_equal bd("0"), master.round(6), "Master TWR must be unchanged by an internal transfer"
  end

  # §23 — DEPOSIT DURING LOSS. -10% then a 100,000 contribution => -10.00%; the
  # larger final NAV must not make the sleeve look profitable.
  test "a contribution during a loss does not mask the loss" do
    values = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(90_000)], [d("2026-01-03"), bd(190_000)]]
    twr = inception_twr(values, flows(d("2026-01-03") => [100_000, 0]))
    assert_equal bd("-10"), twr.round(6)
  end

  # §28 sanity: naive (end/start-1) OVERSTATES when a contribution occurred, while
  # TWR does not — the whole point of the metric.
  test "naive return diverges from TWR when external flows occur" do
    values = [[d("2026-01-01"), bd(100_000)], [d("2026-01-02"), bd(110_000)], [d("2026-01-03"), bd(160_000)]]
    naive = (bd(160_000) / bd(100_000) - 1) * 100 # +60% (wrong: includes the contribution)
    twr = inception_twr(values, flows(d("2026-01-03") => [50_000, 0]))
    assert_equal bd("60"), naive
    assert_equal bd("10"), twr.round(6)
    refute_equal naive.round(6), twr.round(6)
  end
end
