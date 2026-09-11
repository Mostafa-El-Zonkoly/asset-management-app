# frozen_string_literal: true

require "test_helper"

# Risk metric acceptance tests (spec #23–#28). Pure math over a daily-return
# series shaped like the performance engine's DayReturn (date + daily_return).
class PortfolioRiskServiceTest < ActiveSupport::TestCase
  DR = Struct.new(:date, :daily_return, keyword_init: true)

  def d(n) = Date.new(2026, 1, 1) + n

  # First day has no prior return (nil), then one entry per return.
  def series(rets)
    [DR.new(date: d(0), daily_return: nil)] +
      rets.each_with_index.map { |r, i| DR.new(date: d(i + 1), daily_return: r) }
  end

  def svc(rf = 0.0) = PortfolioRiskService.new(risk_free_annual: rf)

  # §25 Max drawdown from the index 100,110,120,108,96,105 => -20%
  test "max drawdown is the deepest peak-to-trough of the compounded index" do
    rets = [10.0 / 100, 10.0 / 110, -12.0 / 120, -12.0 / 108, 9.0 / 96]
    r = svc.from_daily(series(rets))
    assert_in_delta(-0.20, r.max_drawdown, 1e-9)
  end

  # §23 Volatility = daily std * sqrt(252)
  test "annualized volatility equals daily std times sqrt(252)" do
    rets = Array.new(40) { |i| i.even? ? 0.01 : -0.01 }
    r = svc.from_daily(series(rets))
    expected = (0.01 * Math.sqrt(40.0 / 39.0)) * Math.sqrt(252)
    assert_in_delta expected, r.volatility, 1e-9
  end

  # §24 A deposit day is a 0% return; it must not create volatility or drawdown
  test "flat/deposit days create no volatility or drawdown" do
    r = svc.from_daily(series(Array.new(25) { 0.0 }))
    assert_equal 0.0, r.max_drawdown
    assert_in_delta 0.0, r.volatility, 1e-12
  end

  # §26 Consolidated with only internal transfers => all-zero returns => no risk
  test "internal-transfer-only consolidated series has zero risk" do
    r = svc.from_daily(series(Array.new(30) { 0.0 }))
    assert_equal 0.0, r.max_drawdown
    assert_in_delta 0.0, r.volatility, 1e-12
    assert_nil r.sharpe, "sharpe undefined when volatility is zero"
  end

  # §27 Short history (10 days): vol/Sharpe/Sortino/Calmar N/A, MDD available
  test "short history yields N/A for annualized metrics but MDD is available" do
    r = svc.from_daily(series(Array.new(10) { 0.001 }))
    assert_nil r.volatility
    assert_nil r.sharpe
    assert_nil r.sortino
    assert_nil r.calmar
    assert_not_nil r.max_drawdown
  end

  # §28 Common-start clipping: only the shared window is used
  test "from/to window clips the series so comparisons use the same period" do
    rets = Array.new(100) { |i| i.even? ? 0.01 : -0.01 }
    full = series(rets)
    clipped = svc.from_daily(full, from: full[61].date) # window d(61)..d(100)
    assert_equal 40, clipped.n_returns
    assert_equal 100, svc.from_daily(full).n_returns
  end

  test "Sortino returns a no-downside sentinel when every day is up" do
    r = svc.from_daily(series(Array.new(35) { 0.005 }))
    assert_equal :no_downside, r.sortino
  end

  test "Calmar needs >= 90 calendar days of span" do
    short = svc.from_daily(series(Array.new(40) { |i| i.even? ? 0.01 : -0.02 }))
    assert_nil short.calmar, "span < 90 days => Calmar N/A"
  end
end
