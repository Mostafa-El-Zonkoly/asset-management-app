# frozen_string_literal: true

require "test_helper"

# External deposits / withdrawals must be performance-neutral on BOTH bases, while cash
# that stays inside the portfolio keeps counting as wealth (cash drag). DB-free: drives
# the pure ledger / series / return-engine pieces like portfolio_wealth_return_test.rb.
#
# Money model (same as the app): holdings are valued at trade price on trade days, a buy
# settled through the liquidity wallet is wallet cash -> holdings (internal), a wallet
# deposit/withdrawal is external.
class DepositNeutralityTest < ActiveSupport::TestCase
  def setup
    @wealth = PortfolioPerformanceService.new(base_id: 1, basis: :wealth)
    @invested = PortfolioPerformanceService.new(base_id: 1)
  end

  def bd(x) = BigDecimal(x.to_s)
  def d(n) = Date.new(2026, 1, n)
  def fx(date, amount, kind, pid = nil) = { date: date, amount: bd(amount), kind: kind, portfolio_id: pid }

  # holdings: [[Date, value]]; effects: signed wallet effects (see fx).
  def wallet_series(holdings:, effects: [], pid: 1)
    ev = PortfolioWealthSeriesService.wallet_events(effects, pid, [])
    ledger = PortfolioCashLedger.new(opening_cash: bd(0), migration_on: PortfolioWealthSeriesService::EPOCH,
                                     tx_events: ev[:tx_events], flow_events: ev[:flow_events],
                                     boundary_events: ev[:boundary_events])
    PortfolioWealthSeriesService.compose(holdings.map { |dt, v| [dt, bd(v)] }, ledger, source: :liquidity_wallet)
  end

  def daily_of(s)
    @wealth.instance_variable_set(:@wealth_internal, s.internal) # normally set by wealth_values_flows_cash
    @wealth.send(:build_daily, s.values, s.flows, s.cash_values.to_h)
  end

  def total_return(daily, svc = @wealth)
    svc.send(:period_result, daily, :inception, "Since inception", daily.first.date).return_pct
  end

  # Invested TWR input: holdings value + buy(+)/sell(-) flows only; cash never appears.
  def invested_return(values, ext_flows = {})
    f = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: bd(0), dividend: bd(0)) }
    ext_flows.each { |dt, a| f[dt] = PortfolioCashFlowService::Day.new(external: bd(a), dividend: bd(0)) }
    dl = @invested.send(:build_daily, values.map { |dt, v| [dt, bd(v)] }, f)
    total_return(dl, @invested)
  end

  # ---- Test A -------------------------------------------------------------------
  test "A: 80k + 20k deposit kept as cash = 100k wealth and 0% return" do
    s = wallet_series(holdings: [[d(1), 80_000], [d(2), 80_000]], effects: [fx(d(2), 20_000, "deposit")])
    assert_equal bd(100_000), s.values.last.last
    assert_equal bd(0), total_return(daily_of(s))
    assert_equal bd(0), daily_of(s).last.daily_pnl, "the deposit itself is not a profit"
  end

  # ---- Test B -------------------------------------------------------------------
  test "B: 100k + 20k deposit, +2% afterwards => +2%, not +22%" do
    # the 20k is invested through the wallet (internal) and the whole 120k rises 2%
    s = wallet_series(holdings: [[d(1), 100_000], [d(2), 122_400]],
                      effects: [fx(d(2), 20_000, "deposit"), fx(d(2), -20_000, "buy", 1)])
    assert_equal bd("2"), total_return(daily_of(s)).round(6)
  end

  test "B2: the same deposit left as cash only dilutes the move (cash drag), never inflates it" do
    s = wallet_series(holdings: [[d(1), 100_000], [d(2), 102_000]], effects: [fx(d(2), 20_000, "deposit")])
    r = total_return(daily_of(s))
    assert_operator r, :>, 0
    assert_operator r, :<, bd(2)
    assert_equal bd("1.666667"), r.round(6) # 2k / 120k
  end

  # ---- Test C -------------------------------------------------------------------
  test "C: 20k withdrawal from 100k, no market move => 0%" do
    s = wallet_series(holdings: [[d(1), 100_000], [d(2), 80_000]],
                      effects: [fx(d(2), 20_000, "sell", 1), fx(d(2), -20_000, "withdrawal")])
    assert_equal bd(80_000), s.values.last.last
    assert_equal bd(0), total_return(daily_of(s))
  end

  test "C2: a withdrawal taken out of cash alone is 0% too" do
    s = wallet_series(holdings: [[d(1), 70_000], [d(2), 70_000]],
                      effects: [fx(d(1), 30_000, "deposit"), fx(d(2), -20_000, "withdrawal")])
    assert_equal bd(80_000), s.values.last.last
    assert_equal bd(0), total_return(daily_of(s))
  end

  # ---- Test D / E: strategic cash, wealth vs invested ----------------------------
  test "D: 70k invested + 30k cash, no market movement => 0% wealth" do
    s = wallet_series(holdings: [[d(1), 70_000], [d(2), 70_000], [d(3), 70_000]], effects: [fx(d(1), 30_000, "deposit")])
    assert_equal bd(100_000), s.values.last.last
    assert_equal bd(0), total_return(daily_of(s))
  end

  test "E: 70k invested + 30k cash, invested +10% => wealth +7% (107k), invested TWR +10%" do
    s = wallet_series(holdings: [[d(1), 70_000], [d(2), 77_000]], effects: [fx(d(1), 30_000, "deposit")])
    assert_equal bd(107_000), s.values.last.last
    assert_equal bd("7"), total_return(daily_of(s)).round(6)
    assert_equal bd("10"), invested_return([[d(1), 70_000], [d(2), 77_000]]).round(6)
  end

  test "E2: Invested TWR is untouched by deposits that stay as cash" do
    # a deposit never reaches the invested basis (it only sees holdings + buys/sells)
    assert_equal bd(0), invested_return([[d(1), 70_000], [d(2), 70_000], [d(3), 70_000]])
    s = wallet_series(holdings: [[d(1), 70_000], [d(2), 70_000], [d(3), 70_000]],
                      effects: [fx(d(1), 30_000, "deposit"), fx(d(2), 50_000, "deposit")])
    assert_equal bd(0), total_return(daily_of(s)), "deposits are neutral for Wealth too"
  end

  # ---- Test F: two portfolios, different deposits, same date ---------------------
  test "F: different deposits on the same date keep both curves continuous" do
    days = [d(1), d(2), d(3), d(4)]
    borsa = wallet_series(holdings: days.map { |x| [x, 77_900] }, effects: [fx(d(1), 10_000, "deposit"), fx(d(3), 15_000, "deposit")], pid: 1)
    core = wallet_series(holdings: days.map { |x| [x, 52_000] }, effects: [fx(d(1), 35_200, "deposit"), fx(d(3), 6_000, "deposit")], pid: 2)

    [borsa, core].each do |s|
      pts = @wealth.normalize(daily_of(s), from: d(1), to: d(4))
      assert_equal [100.0] * 4, pts.map { |p| p[1] }, "flat market + deposits => flat index"
    end

    # and with a real market move on the deposit day only the move shows
    b2 = wallet_series(holdings: [[d(1), 77_900], [d(2), 77_900], [d(3), 77_900 * 1.01]], effects: [fx(d(1), 10_000, "deposit"), fx(d(3), 15_000, "deposit")])
    idx = @wealth.normalize(daily_of(b2), from: d(1), to: d(3)).map { |p| p[1] }
    assert_equal 100.0, idx[1]
    assert_in_delta 100.0 * (1 + 779.0 / (87_900 + 15_000)), idx[2], 0.01 # +779 on 102.9k, not +17%

    # combined "All portfolios": the two deposits sum, still no jump
    combined = @wealth.tap { |svc| svc.instance_variable_get(:@wealth_cache)[[1, "all"]] = borsa; svc.instance_variable_get(:@wealth_cache)[[2, "all"]] = core }
                      .daily_for([Struct.new(:id, :name).new(1, "Borsa"), Struct.new(:id, :name).new(2, "Core")], role: "all")
    assert_equal bd(21_000), combined.find { |r| r.date == d(3) }.external
    assert_equal bd(0), total_return(combined)
  end

  # ---- Test G: common-start normalisation ----------------------------------------
  test "G: common start rebases portfolios and benchmark to 100; later deposits cause no discontinuity" do
    days = (1..6).map { |n| d(n) }
    early = wallet_series(holdings: days.map { |x| [x, 80_000] }, effects: [fx(d(1), 10_000, "deposit"), fx(d(5), 20_000, "deposit")], pid: 1)
    late = wallet_series(holdings: days.drop(2).map { |x| [x, 50_000] }, effects: [fx(d(3), 5_000, "deposit"), fx(d(5), 8_000, "deposit")], pid: 2)
    prices = [1000, 1010, 1020.1, 1030.301, 1040.60401, 1051.0100501].map { |p| bd(p) }
    bench = days.each_with_index.map do |x, i|
      PortfolioPerformanceService::DayReturn.new(date: x, value: prices[i], external: bd(0), dividend: bd(0),
                                                 daily_return: i.zero? ? nil : prices[i] / prices[i - 1] - 1, daily_pnl: nil)
    end

    start = [early, late].map { |s| daily_of(s).first.date }.max
    assert_equal d(3), start
    series = [daily_of(early), daily_of(late), bench].map { |dd| @wealth.normalize(dd, from: d(1), to: d(6), start_on: start) }

    series.each { |pts| assert_equal [d(3).iso8601, 100.0], pts.first.first(2), "rebased to 100 on the common start" }
    series.each { |pts| assert_equal [d(3), d(4), d(5), d(6)].map(&:iso8601), pts.map(&:first) }
    assert_equal [100.0] * 4, series[0].map { |p| p[1] }, "early: deposit on d5 is invisible"
    assert_equal [100.0] * 4, series[1].map { |p| p[1] }, "late: deposits on d3/d5 are invisible"
    assert_in_delta 100.0 * 1.01**3, series[2].last[1], 0.01, "benchmark compounds its own price return"
  end

  # ---- Regression: the reported collapse ------------------------------------------
  test "regression: deposit to the wallet then contribute it to the portfolio does not move the index" do
    flat = [[d(1), 77_900], [d(2), 77_900], [d(3), 77_900]]
    s = wallet_series(holdings: flat, effects: [fx(d(1), 20_000, "deposit"), fx(d(3), 15_000, "deposit"), fx(d(3), -15_000, "contribution", 1)])
    assert_equal bd(112_900), s.values.last.last, "the 15k is still managed wealth"
    pts = @wealth.normalize(daily_of(s), from: d(1), to: d(3))
    assert_equal [100.0, 100.0, 100.0], pts.map { |p| p[1] }
  end

  # ---- Safeguards -----------------------------------------------------------------
  test "safeguard: a flow whose cash leg is missing from the value is flagged as suspicious" do
    # value does not include the 15k although 15k of external flow is booked => -16% on a pure deposit
    bad = @wealth.send(:build_daily, [[d(1), bd(77_900)], [d(2), bd(77_900)]],
                       { d(2) => PortfolioCashFlowService::Day.new(external: bd(15_000), dividend: bd(0)) })
    flagged = PortfolioPerformanceService.suspicious_days(bad)
    assert_equal [d(2)], flagged.map(&:date)
    assert_operator bad.last.daily_return, :<, bd("-0.1")

    ok = daily_of(wallet_series(holdings: [[d(1), 77_900], [d(2), 77_900]], effects: [fx(d(2), 15_000, "deposit")]))
    assert_empty PortfolioPerformanceService.suspicious_days(ok)
  end

  test "safeguard: out-of-order valuation points do not create jumps" do
    shuffled = [[d(3), bd(110)], [d(1), bd(100)], [d(2), bd(105)]]
    ledger = PortfolioCashLedger.new(opening_cash: bd(0), migration_on: d(1) - 1)
    s = PortfolioWealthSeriesService.compose(shuffled, ledger)
    assert_equal [d(1), d(2), d(3)], s.values.map(&:first)
    assert_equal bd("10"), total_return(daily_of(s)).round(6)
    # the engine itself also sorts
    assert_equal [d(1), d(2), d(3)], @wealth.send(:build_daily, shuffled, {}).map(&:date)
  end

  test "safeguard: a deposit is counted once - in cash and in flow, never twice" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 100]], effects: [fx(d(1), 50, "deposit"), fx(d(2), 25, "deposit")])
    assert_equal bd(25), s.flows[d(2)].external
    assert_equal bd(175), s.values.last.last
    assert_equal s.values.last.last, s.values.first.last + s.flows[d(2)].external + daily_of(s).last.daily_pnl
  end
  # ---- Test G2: deposit on a day with market movement -----------------------------
  test "G2: deposit on a market-move day is neutralised while the genuine return remains" do
    # 100k, then on d2: +20k deposit kept as cash and the original 100k gains 3%.
    s = wallet_series(holdings: [[d(1), 100_000], [d(2), 103_000]], effects: [fx(d(2), 20_000, "deposit")])
    r = daily_of(s).last
    assert_equal bd(123_000), r.value
    assert_equal bd(3_000), r.daily_pnl, "pnl is the market gain only, not +23k"
    assert_equal bd("2.5"), (r.daily_return * 100).round(6) # 3k on 120k (cash drag included)
  end

  # ---- Test H: deposit + buy the same day -----------------------------------------
  test "H: deposit and buy on the same date are counted once" do
    s = wallet_series(holdings: [[d(1), 50_000], [d(2), 70_000], [d(3), 70_000]],
                      effects: [fx(d(1), 10_000, "deposit"), fx(d(2), 20_000, "deposit"), fx(d(2), -20_000, "buy", 1)])
    day2 = daily_of(s)[1]
    assert_equal bd(20_000), day2.external, "only the deposit is external"
    assert_equal bd(0), day2.daily_pnl
    assert_equal bd(-20_000), day2.internal, "the buy is an internal cash->holdings move"
    assert_equal bd(10_000), s.cash_values[1].last, "cash = 10k opening + 20k deposit - 20k buy"
    assert_equal bd(80_000), s.values[1].last
  end

  # ---- Test I: withdrawal after selling -------------------------------------------
  test "I: sale proceeds are internal cash until they leave the portfolio" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 40], [d(3), 40]],
                      effects: [fx(d(2), 60, "sell", 1), fx(d(3), -60, "withdrawal")])
    dl = daily_of(s)
    assert_equal bd(0), dl[1].external, "selling is not a withdrawal"
    assert_equal bd(100), dl[1].value, "proceeds stay in wealth"
    assert_equal bd(-60), dl[2].external, "only the withdrawal is external"
    assert_equal bd(40), dl[2].value
    assert_equal bd(0), total_return(dl)
  end

  # ---- Test J: dividends are return, deposits are not ------------------------------
  test "J: a dividend credited to cash is performance; an equal deposit is not" do
    div = wallet_series(holdings: [[d(1), 100], [d(2), 100]], effects: [fx(d(1), 0, "deposit"), fx(d(2), 5, "cash_dividend", 1)])
    assert_equal bd(0), div.flows[d(2)].external
    assert_equal bd("5"), total_return(daily_of(div)).round(6)

    dep = wallet_series(holdings: [[d(1), 100], [d(2), 100]], effects: [fx(d(2), 5, "deposit")])
    assert_equal bd(5), dep.flows[d(2)].external
    assert_equal bd(0), total_return(daily_of(dep))
  end

  test "fees are internal cost (negative return); the invested basis never sees cash" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 100]], effects: [fx(d(1), 20, "deposit"), fx(d(2), -2, "buy", 1)])
    assert_equal bd(0), s.flows[d(2)].external
  end

  # ---- common start == 100 * cum_t / cum_start --------------------------------------
  test "common-start normalisation equals 100 * cumulative_t / cumulative_at_start" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 110], [d(3), 110], [d(4), 121]], effects: [fx(d(1), 0, "deposit"), fx(d(3), 50, "deposit")])
    dl = daily_of(s)
    cum = dl.each_with_object([]) { |r, a| a << (a.last || 1.to_d) * (1 + (r.daily_return || 0)) }
    pts = @wealth.normalize(dl, from: d(1), to: d(4), start_on: d(2))
    pts.each_with_index do |p, i|
      assert_in_delta (100 * cum[i + 1] / cum[1]).to_f, p[1], 0.01
    end
  end

  # ---- Diagnostics ------------------------------------------------------------------
  test "debug logging is off by default and, when on, explains each day" do
    lines = []
    PerformanceDebugLog.sink = ->(l) { lines << l }
    s = wallet_series(holdings: [[d(1), 70_000], [d(2), 77_000]], effects: [fx(d(1), 30_000, "deposit")])

    ENV.delete("DEBUG_PERFORMANCE")
    daily_of(s)
    assert_empty lines

    ENV["DEBUG_PERFORMANCE"] = "1"
    daily_of(s)
    day = lines.grep(/"event":"day"/).last
    %w[previous_total_wealth holdings_market_value cash_balance external_deposits external_withdrawals dividends
       internal_cash_in internal_cash_out ending_total_wealth calculated_period_return cumulative_return].each do |k|
      assert_includes day, "\"#{k}\""
    end
    assert_includes day, '"ending_total_wealth":107000.0'
    assert_includes day, '"calculated_period_return":0.07'
  ensure
    ENV.delete("DEBUG_PERFORMANCE")
    PerformanceDebugLog.sink = nil
  end
end
