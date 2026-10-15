# frozen_string_literal: true

require "test_helper"

# Wealth Return (holdings + retained portfolio cash) acceptance tests.
#
# DB-free, like twr_semantics_test.rb: they drive the pure pieces —
# PortfolioCashLedger, PortfolioWealthSeriesService.compose and the shared Modified
# Dietz engine — and the combined path of PortfolioPerformanceService with pre-built
# per-portfolio wealth series.
#
# Modelling used throughout (same as the app): holdings are valued at the trade price
# on trade days, so a sell lowers holdings by exactly its proceeds and the proceeds
# land in portfolio cash (ledger event +). External flows are ONLY PortfolioCashFlow
# rows (contribution/withdrawal/transfer).
class PortfolioWealthReturnTest < ActiveSupport::TestCase
  Portfolio = Struct.new(:id, :name)

  def setup
    @svc = PortfolioPerformanceService.new(base_id: 1, basis: :wealth)
  end

  def bd(x) = BigDecimal(x.to_s)
  def d(n) = Date.new(2026, 1, n)

  # holdings: [[Date, value]]; tx/flows: [[Date, signed cash]].
  def series(holdings:, opening_cash: 0, migration_on: d(1), tx: [], flows: [])
    ledger = PortfolioCashLedger.new(
      opening_cash: bd(opening_cash), migration_on: migration_on,
      tx_events: tx.map { |dt, a| [dt, bd(a)] }, flow_events: flows.map { |dt, a| [dt, bd(a)] }
    )
    PortfolioWealthSeriesService.compose(holdings.map { |dt, v| [dt, bd(v)] }, ledger)
  end

  def daily_of(s)
    @svc.send(:build_daily, s.values, s.flows, s.cash_values.to_h)
  end

  def wealth_twr(s)
    dl = daily_of(s)
    @svc.send(:period_result, dl, :inception, "Since inception", dl.first.date).return_pct
  end

  # The ORIGINAL invested-assets TWR (holdings only; buy = +flow, sell = -flow).
  def invested_twr(values, ext_flows)
    inv = PortfolioPerformanceService.new(base_id: 1)
    f = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: bd(0), dividend: bd(0)) }
    ext_flows.each { |dt, a| f[dt] = PortfolioCashFlowService::Day.new(external: bd(a), dividend: bd(0)) }
    dl = inv.send(:build_daily, values.map { |dt, v| [dt, bd(v)] }, f)
    inv.send(:period_result, dl, :inception, "Since inception", dl.first.date).return_pct
  end

  # Stand-in for per-portfolio wealth series so the combined row runs the real code path.
  def combined_daily(entries)
    ports = entries.keys
    entries.each { |p, s| @svc.instance_variable_get(:@wealth_cache)[[p.id, "all"]] = s }
    @svc.daily_for(ports, role: "all")
  end

  def inception_of(dl)
    @svc.send(:period_result, dl, :inception, "Since inception", dl.first.date).return_pct
  end

  # ---- headline example -------------------------------------------------------

  test "6: partial de-risking 100 -> 50 cash + 50 stock -> stock falls to 40 is -10% wealth, -20% invested" do
    holdings = [[d(1), 100], [d(2), 50], [d(3), 40]]
    s = series(holdings: holdings, tx: [[d(2), 50]]) # sell 50 -> +50 cash

    assert_equal [bd(100), bd(100), bd(90)], s.values.map(&:last)
    assert_equal bd("-10"), wealth_twr(s).round(6)

    # Same history through the unchanged Invested TWR: the sale is an outflow of 50.
    assert_equal bd("-20"), invested_twr(holdings, d(2) => -50).round(6)
  end

  test "cash weight is exposed so the difference is explainable" do
    s = series(holdings: [[d(1), 100], [d(2), 50], [d(3), 40]], tx: [[d(2), 50]])
    last = daily_of(s).last
    assert_equal bd(50), last.cash
    assert_in_delta 55.5556, @svc.send(:cash_weight, last).to_f, 0.0001
  end

  # ---- 1/2: sells and internal moves ----------------------------------------

  test "1: selling stock to cash does not change wealth by itself" do
    s = series(holdings: [[d(1), 100], [d(2), 50]], tx: [[d(2), 50]])
    assert_equal bd(100), s.values.last.last
    assert_equal bd(0), wealth_twr(s)
    assert_equal bd(0), daily_of(s).last.daily_pnl
  end

  test "2: Core -> cash sleeve (transfer between portfolios) creates no return in the combined series" do
    core = series(holdings: [[d(1), 100], [d(2), 50], [d(3), 50]], tx: [[d(2), 50]], flows: [[d(2), -50]])
    sleeve = series(holdings: [[d(1), 0], [d(2), 0], [d(3), 0]], flows: [[d(2), 50]])
    both = combined_daily(Portfolio.new(1, "Core") => core, Portfolio.new(2, "Sleeve") => sleeve)

    assert_equal bd(0), inception_of(both)
    assert_equal [bd(100)] * 3, both.map(&:value)
  end

  # ---- 3: portfolio transfer nets in All ------------------------------------

  test "3: Core -> Borsa Halal transfer nets to zero in All portfolios while a real move still shows" do
    # d2: Core sells 50 and transfers it out; Borsa receives it and buys 50. d3: everything +10%.
    core = series(holdings: [[d(1), 100], [d(2), 50], [d(3), 55]], tx: [[d(2), 50]], flows: [[d(2), -50]])
    borsa = series(holdings: [[d(1), 50], [d(2), 100], [d(3), 110]], tx: [[d(2), -50]], flows: [[d(2), 50]])

    both = combined_daily(Portfolio.new(1, "Core") => core, Portfolio.new(2, "Borsa Halal") => borsa)

    d2 = both.find { |x| x.date == d(2) }
    assert_equal bd(0), d2.external, "transfer legs must cancel"
    assert_equal bd(0), d2.daily_pnl
    assert_equal bd("10"), inception_of(both).round(6)
  end

  test "a transfer to a portfolio OUTSIDE the selection is an external withdrawal for that selection" do
    core = series(holdings: [[d(1), 100], [d(2), 50]], tx: [[d(2), 50]], flows: [[d(2), -50]])
    alone = combined_daily(Portfolio.new(1, "Core") => core)
    assert_equal bd(-50), alone.find { |x| x.date == d(2) }.external
    assert_equal bd(0), inception_of(alone)
  end

  # ---- 4/5: external flows ---------------------------------------------------

  test "4: an external deposit of 20 (invested or left as cash) is not performance" do
    invested = series(holdings: [[d(1), 100], [d(2), 120]], tx: [[d(2), -20]], flows: [[d(2), 20]]) # +20, then buy 20
    assert_equal bd(0), wealth_twr(invested)

    as_cash = series(holdings: [[d(1), 100], [d(2), 100]], flows: [[d(2), 20]]) # deposit stays as cash
    assert_equal bd(120), as_cash.values.last.last
    assert_equal bd(0), wealth_twr(as_cash)
  end

  test "5: money withdrawn out of the managed universe leaves wealth and creates no artificial loss" do
    # Sell 50, then take the 50 out entirely.
    s = series(holdings: [[d(1), 100], [d(2), 50], [d(3), 40]], tx: [[d(2), 50]], flows: [[d(2), -50]])
    assert_equal [bd(100), bd(50), bd(40)], s.values.map(&:last)
    d2 = daily_of(s).find { |x| x.date == d(2) }
    assert_equal bd(0), d2.daily_pnl, "the withdrawal itself is not a loss"
    # The withdrawn 50 is gone, so the later fall is -20% of the 50 still managed.
    assert_equal bd("-20"), wealth_twr(s).round(6)
  end

  # ---- 7/8: fully cash and re-entry ------------------------------------------

  test "7: 100% cash stays ~0% when the market falls" do
    s = series(holdings: [[d(1), 100], [d(2), 0], [d(3), 0]], tx: [[d(2), 100]])
    assert_equal bd(0), wealth_twr(s)
    assert_equal bd(100), s.values.last.last
  end

  test "8: re-entry (cash used to buy securities) is an allocation change with no jump" do
    s = series(holdings: [[d(1), 100], [d(2), 50], [d(3), 100], [d(4), 110]], tx: [[d(2), 50], [d(3), -50]])
    dl = daily_of(s)
    assert_equal bd(0), dl.find { |x| x.date == d(3) }.daily_pnl
    assert_equal bd("10"), wealth_twr(s).round(6)
  end

  # ---- 9/10: dividends, fees --------------------------------------------------

  test "9: cash dividends retained in the portfolio are part of wealth (counted once)" do
    s = series(holdings: [[d(1), 100], [d(2), 100]], tx: [[d(2), 5]])
    dl = daily_of(s)
    assert_equal bd(5), dl.last.daily_pnl
    assert_equal bd(0), dl.last.dividend, "dividend is already in cash; must not be added again"
    assert_equal bd("5"), wealth_twr(s).round(6)
  end

  test "10: fees/taxes use the app's existing cash signs" do
    signs = PortfolioAccountingService::CASH_TX_SIGN
    assert_equal({ "buy" => -1, "sell" => 1, "cash_dividend" => 1, "deduction" => -1 }, signs)
    # 100 holdings + 100 cash; a deduction of 2 => -2 cash => -1% of 200.
    s = series(holdings: [[d(1), 100], [d(2), 100]], opening_cash: 100, tx: [[d(2), 2 * signs["deduction"]]])
    assert_equal bd("-1"), wealth_twr(s).round(6)
  end

  # ---- 11: missing data -> N/A ------------------------------------------------

  test "11: no valuation on/after migration, or negative cash, is N/A with a reason (never fabricated)" do
    none = series(holdings: [[d(1), 100]], migration_on: d(5))
    refute none.available?
    assert_equal :before_migration, none.reason

    # A 100 buy with no contribution and no opening cash: cash would be -100.
    neg = series(holdings: [[d(1), 0], [d(2), 100]], tx: [[d(2), -100]])
    refute neg.available?
    assert_equal :negative_cash, neg.reason
    assert_match(/2026-01-02/, PortfolioWealthSeriesService.reason_text(neg))
  end

  test "11: an unavailable portfolio makes the row N/A and names the reason; one gap makes All N/A" do
    ok = series(holdings: [[d(1), 100], [d(2), 100]])
    bad = PortfolioWealthSeriesService.unavailable(:not_migrated)
    core = Portfolio.new(1, "Core")
    other = Portfolio.new(2, "Other")
    @svc.instance_variable_get(:@wealth_cache)[[1, "all"]] = ok
    @svc.instance_variable_get(:@wealth_cache)[[2, "all"]] = bad

    note = @svc.send(:wealth_unavailable_note, [core, other], "all")
    assert_match(/Other: no liquidity wallet is assigned and no opening-capital baseline/, note)
    assert_equal [[], {}, {}], @svc.send(:wealth_values_flows_cash, [core, other], "all")

    row = @svc.row_for([other], label: "Other", scope: other, role: "all", as_of: d(10))
    assert row.periods.values.none?(&:available)
    assert_match(/no opening-capital baseline/, row.note)
    assert_equal :wealth, row.basis
  end

  test "11: trailing periods still need history (N/A preserved)" do
    s = series(holdings: [[d(1), 100], [d(2), 101]])
    dl = daily_of(s)
    res = @svc.send(:period_result, dl, :m1, "1M", dl.first.date)
    refute res.available
  end

  test "role filter makes wealth N/A (cash is not attributed to roles)" do
    s = PortfolioWealthSeriesService.new(Portfolio.new(1, "Core"), role: "base", base_id: 1).call
    refute s.available?
    assert_equal :role_filter, s.reason
  end

  # ---- 12: corporate actions --------------------------------------------------

  test "12: splits/bonus shares are not cash and not return when value is unchanged" do
    refute_includes PortfolioAccountingService::CASH_TX_SIGN.keys, "stock_dividend"
    # 2-for-1: quantity doubles, price halves => holdings value flat across the action.
    s = series(holdings: [[d(1), 100], [d(2), 100], [d(3), 100]])
    assert_equal bd(0), wealth_twr(s)
  end

  # ---- ledger mechanics -------------------------------------------------------

  test "ledger: opening cash anchors the balance; transactions on/before migration are not replayed" do
    ledger = PortfolioCashLedger.new(
      opening_cash: bd(30), migration_on: d(2),
      tx_events: [[d(1), bd(999)], [d(2), bd(999)], [d(3), bd(10)]],
      flow_events: [[d(4), bd(5)]]
    )
    assert_equal bd(30), ledger.cash_on(d(2))
    assert_equal bd(40), ledger.cash_on(d(3))
    assert_equal bd(45), ledger.cash_on(d(10))
  end

  test "series starts at the migration date and opening cash is part of wealth" do
    s = series(holdings: [[d(1), 80], [d(2), 90], [d(3), 99]], opening_cash: 30, migration_on: d(2))
    assert_equal d(2), s.start
    assert_equal [bd(120), bd(129)], s.values.map(&:last)
  end

  test "starting wealth enters as capital once; earlier flows are not double counted" do
    s = series(holdings: [[d(2), 100], [d(3), 100]], migration_on: d(1),
               tx: [[d(2), -100]], flows: [[d(1), 100]]) # contribute 100 on d1, buy 100 on d2
    assert_equal({ d(2) => bd(100) }, s.flows.transform_values(&:external))
  end

  test "a flow dated between valuation dates is bucketed into the next valuation window" do
    s = series(holdings: [[d(1), 100], [d(3), 100]], flows: [[d(2), 25]])
    assert_equal bd(125), s.values.last.last
    assert_equal bd(0), wealth_twr(s)
  end

  # ---- invested basis is untouched -------------------------------------------

  test "invested basis keeps 5-element chart points and no cash data" do
    inv = PortfolioPerformanceService.new(base_id: 1)
    dl = inv.send(:build_daily, [[d(1), bd(100)], [d(2), bd(101)]],
                  Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: bd(0), dividend: bd(0)) })
    assert_nil dl.last.cash
    pts = inv.normalize(dl, from: d(1), to: d(2))
    assert_equal 5, pts.first.size
    assert_equal 6, @svc.normalize(daily_of(series(holdings: [[d(1), 100], [d(2), 101]])), from: d(1), to: d(2)).first.size
  end

  # ===== Liquidity wallet scope =================================================
  # effects = signed effect ON the wallet: { date:, amount:, kind:, portfolio_id: }.
  def wallet_series(holdings:, effects: [], elsewhere: [], pid: 1)
    ev = PortfolioWealthSeriesService.wallet_events(effects, pid, elsewhere)
    ledger = PortfolioCashLedger.new(opening_cash: bd(0), migration_on: PortfolioWealthSeriesService::EPOCH,
                                     tx_events: ev[:tx_events], flow_events: ev[:flow_events],
                                     boundary_events: ev[:boundary_events])
    PortfolioWealthSeriesService.compose(holdings.map { |dt, v| [dt, bd(v)] }, ledger, source: :liquidity_wallet)
  end

  def fx(date, amount, kind, pid = nil) = { date: date, amount: bd(amount), kind: kind, portfolio_id: pid }

  test "wallet: sell 50 into the liquidity wallet, stock falls to 40 => -10% (not -20%)" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 50], [d(3), 40]], effects: [fx(d(2), 50, "sell", 1)])
    assert_equal [bd(100), bd(100), bd(90)], s.values.map(&:last)
    assert_equal bd("-10"), wealth_twr(s).round(6)
  end

  test "wallet: moving money between the portfolio and its wallet is internal (zero performance impact)" do
    # sell 50 (wallet +50), later the portfolio redeploys 20 from the wallet via a cash flow.
    s = wallet_series(
      holdings: [[d(1), 100], [d(2), 50], [d(3), 70]],
      effects: [fx(d(2), 50, "sell", 1), fx(d(3), -20, "contribution", 1)]
    )
    assert_equal bd(0), wealth_twr(s)
    assert_equal({ d(1) => bd(100) }, s.flows.transform_values(&:external))
  end

  test "wallet: deposits and withdrawals on the wallet are external and neutralised" do
    s = wallet_series(
      holdings: [[d(1), 100], [d(2), 100], [d(3), 100]],
      effects: [fx(d(2), 40, "deposit"), fx(d(3), -30, "withdrawal")]
    )
    assert_equal [bd(100), bd(140), bd(110)], s.values.map(&:last)
    assert_equal bd(0), wealth_twr(s)
  end

  test "wallet: another portfolio's trade through this wallet is an external flow for this portfolio" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 100]], effects: [fx(d(1), 50, "deposit"), fx(d(2), -10, "buy", 2)])
    assert_equal bd(-10), s.flows[d(2)].external
    assert_equal bd(0), wealth_twr(s)
  end

  test "wallet: own buy settled through another wallet crosses the boundary (external)" do
    s = wallet_series(holdings: [[d(1), 100], [d(2), 120]], elsewhere: [{ date: d(2), amount: bd(20) }])
    assert_equal bd(20), s.flows[d(2)].external
    assert_equal bd(0), wealth_twr(s)
  end

  test "wallet: a wallet-to-wallet transfer between two selected portfolios nets to zero in All" do
    a = wallet_series(holdings: [[d(1), 100], [d(2), 100], [d(3), 110]], effects: [fx(d(1), 50, "deposit"), fx(d(2), -50, "transfer")], pid: 1)
    b = wallet_series(holdings: [[d(1), 100], [d(2), 100], [d(3), 100]], effects: [fx(d(2), 50, "transfer")], pid: 2)
    both = combined_daily(Portfolio.new(1, "A") => a, Portfolio.new(2, "B") => b)
    d2 = both.find { |x| x.date == d(2) }
    assert_equal bd(0), d2.external
    assert_equal bd(0), d2.daily_pnl
  end

  test "cash-only portfolio: valid axis from market dates, 0% return" do
    axis = PortfolioWealthSeriesService.cash_only_axis([d(2)], [d(1), d(2), d(3), d(4)])
    assert_equal [d(2), d(3), d(4)], axis
    assert_equal [d(5)], PortfolioWealthSeriesService.cash_only_axis([d(5)], [d(1)]) # no later market date
    s = wallet_series(holdings: axis.map { |x| [x, 0] }, effects: [fx(d(2), 100, "deposit")])
    assert_equal bd(100), s.values.last.last
    assert_equal bd(0), wealth_twr(s)
  end

  # ===== Partial validity ======================================================
  test "negative cash only after a date keeps earlier history valid and records the cut-off" do
    holdings = [[d(1), 100], [d(2), 110], [d(3), 120], [d(4), 130], [d(5), 140]]
    s = series(holdings: holdings, opening_cash: 10, tx: [[d(4), -50]]) # cash 10 -> -40 on d4
    assert s.available?
    assert_equal d(3), s.through
    assert_equal d(3), s.values.last.first
    assert_equal bd("18.181818"), wealth_twr(s).round(6) # 110 -> 130, measured only through d3
  end

  test "truncated scope: other periods are N/A, since-inception is kept, combined ends at the cut-off" do
    ok = series(holdings: [[d(1), 100], [d(2), 100], [d(3), 100], [d(4), 100]])
    cut = series(holdings: [[d(1), 100], [d(2), 110], [d(3), 120], [d(4), 130]], opening_cash: 0, tx: [[d(4), -500]])
    p1 = Portfolio.new(1, "OK"); p2 = Portfolio.new(2, "Cut")
    @svc.instance_variable_get(:@wealth_cache)[[1, "all"]] = ok
    @svc.instance_variable_get(:@wealth_cache)[[2, "all"]] = cut
    @svc.define_singleton_method(:snapshots_final?) { |_p, _d| true }

    row = @svc.row_for([p1, p2], label: "All", scope: :combined, role: "all", as_of: d(10))
    assert_equal d(3), row.last_date
    assert row.periods[:inception].available
    assert row.periods.except(:inception).values.none?(&:available)
    assert_match(/reliable only through 2026-01-03/, row.note)
  end

  # ===== Calendar (quarter / year / overall) ===================================
  def jan(day) = Date.new(2026, 1, day)

  test "calendar: Q1 10k -> 15k is +50% and Q2 opens at 15k" do
    s = series(holdings: [[jan(2), 10_000], [Date.new(2026, 3, 31), 15_000], [Date.new(2026, 4, 30), 15_000], [Date.new(2026, 6, 30), 18_000]],
               migration_on: jan(1))
    dl = daily_of(s)
    q = @svc.calendar_periods(dl, :quarter)
    assert_equal ["2026 Q1", "2026 Q2"], q.map(&:label)
    assert_equal [bd(10_000), bd(15_000)], q.map(&:opening)
    assert_equal bd("50"), q[0].return_pct.round(6)
    assert_equal bd("20"), q[1].return_pct.round(6)
    assert_equal bd(18_000), q[1].closing
    assert_equal bd("80"), @svc.overall_period(dl).return_pct.round(6) # 18k / 10k
    assert q.all?(&:complete)
  end

  test "calendar: money added in Q2 is not performance" do
    s = series(holdings: [[jan(2), 10_000], [Date.new(2026, 3, 31), 15_000], [Date.new(2026, 4, 30), 15_000], [Date.new(2026, 6, 30), 16_000]],
               migration_on: jan(1), flows: [[Date.new(2026, 5, 15), 5_000]]) # +5k deposit kept as cash
    q2 = @svc.calendar_periods(daily_of(s), :quarter).last
    assert_equal bd(15_000), q2.opening
    assert_equal bd(5_000), q2.net_flow
    assert_equal bd(1_000), q2.gain
    assert_equal bd(21_000), q2.closing
    assert_equal bd("5.714286"), q2.return_pct.round(6) # 1000 / (15000 + 0.5 * 5000), not +40%
    assert_equal bd(q2.opening + q2.net_flow + q2.gain), q2.closing
  end

  test "calendar: yearly periods chain and an unfinished period is flagged" do
    s = series(holdings: [[Date.new(2025, 12, 1), 100], [Date.new(2025, 12, 31), 110], [Date.new(2026, 2, 1), 121]], migration_on: Date.new(2025, 12, 1))
    y = @svc.calendar_periods(daily_of(s), :year)
    assert_equal %w[2025 2026], y.map(&:label)
    assert_equal bd("10"), y[0].return_pct.round(6)
    assert_equal bd("10"), y[1].return_pct.round(6)
    assert y[0].complete
    refute y[1].complete
  end
end
