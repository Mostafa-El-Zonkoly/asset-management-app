# frozen_string_literal: true

require "test_helper"

# Accounting acceptance tests (spec AP: tests 1–8). Holdings market value is stubbed
# so these isolate the boundary-accounting math; buy/sell rows are created directly
# to exercise the internal-recycling cash effects.
class PortfolioAccountingServiceTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_seed
    @egp = Currency.find_by!(code: "EGP")
    @wallet = Asset.wallets.first || Asset.find_by!(code: "CASH_EGP")
    @stock = Asset.create!(
      name: "Test Co #{SecureRandom.hex(3)}", code: "TST#{SecureRandom.hex(3)}",
      category: Category.find_by!(name: "EGX Stocks"), asset_type: AssetType.find_by!(key: "direct_stock"),
      currency: @egp
    )
    @portfolio = Portfolio.create!(name: "Acct #{SecureRandom.hex(3)}")
  end

  def bd(x) = BigDecimal(x.to_s)

  def buy!(amount, on: Time.zone.local(2026, 2, 1))
    trade!("buy", amount, on)
  end

  def sell!(amount, on: Time.zone.local(2026, 2, 2))
    trade!("sell", amount, on)
  end

  def trade!(key, amount, on)
    PortfolioTransaction.create!(
      portfolio: @portfolio, asset: @stock, transaction_type: TransactionType.find_by!(key: key),
      quantity: 1, price_per_unit: amount, total_amount: amount, currency: @egp, date: on
    )
  end

  def result(holdings: 0)
    stub = { total_value: bd(holdings), total_cost: bd(0), unrealised_gain: bd(0),
             unrealised_gain_pct: bd(0), realised_gain: bd(0), total_gain: bd(0) }
    PortfolioStatsService.stub(:summary, stub) do
      PortfolioAccountingService.call(@portfolio)
    end
  end

  # TEST 1 — reinvestment: contribution 100, buy/sell recycling to 225 cash
  test "T1 reinvestment: invested capital is the contribution, not cumulative buys" do
    CashTransferService.new.contribute!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 100, currency_id: @egp.id)
    buy!(100); sell!(150); buy!(150); sell!(225)
    r = result(holdings: 0)
    assert_equal bd(100), r.contributions
    assert_equal bd(0), r.withdrawals
    assert_equal bd(225), r.cash
    assert_equal bd(225), r.nav
    assert_equal bd(225), r.total_wealth
    assert_equal bd(125), r.net_profit
    assert_equal bd(125), r.simple_roi
    refute_equal bd(250), r.contributions, "must not treat cumulative buys as invested capital"
  end

  # TEST 2 — withdrawal keeps historical wealth
  test "T2 withdrawal: NAV drops but total wealth and ROI are preserved" do
    CashTransferService.new.contribute!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 100, currency_id: @egp.id)
    buy!(100); sell!(150); buy!(150); sell!(225)
    CashTransferService.new.withdraw!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 50, currency_id: @egp.id)
    r = result(holdings: 0)
    assert_equal bd(100), r.contributions
    assert_equal bd(50), r.withdrawals
    assert_equal bd(175), r.nav
    assert_equal bd(225), r.total_wealth
    assert_equal bd(125), r.simple_roi
  end

  # TEST 3 — partial reinvestment leaves cash, no new contribution
  test "T3 partial reinvestment: leftover cash, contributions unchanged" do
    CashTransferService.new.contribute!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 100, currency_id: @egp.id)
    buy!(100); sell!(150); buy!(100)
    r = result(holdings: 100)
    assert_equal bd(50), r.cash
    assert_equal bd(100), r.contributions
  end

  # TEST 4 — new external money increases contributions; prior profit does not
  test "T4 new external money adds to contributions, profit does not" do
    CashTransferService.new.contribute!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 100, currency_id: @egp.id)
    CashTransferService.new.contribute!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 50, currency_id: @egp.id)
    r = result(holdings: 120)
    assert_equal bd(150), r.contributions
  end

  # TEST 6 — portfolio-to-portfolio transfer nets out at Master level
  test "T6 transfer is external per-portfolio but internal (zero) at Master" do
    okaz = Portfolio.create!(name: "Okaz #{SecureRandom.hex(3)}")
    CashTransferService.new.contribute!(portfolio_id: @portfolio.id, wallet_id: @wallet.id, amount: 50_000, currency_id: @egp.id)
    CashTransferService.new.transfer!(source_id: @portfolio.id, dest_id: okaz.id, amount: 20_000, currency_id: @egp.id)

    stub = { total_value: bd(0), total_cost: bd(0), unrealised_gain: bd(0),
             unrealised_gain_pct: bd(0), realised_gain: bd(0), total_gain: bd(0) }
    PortfolioStatsService.stub(:summary, stub) do
      core = PortfolioAccountingService.call(@portfolio)
      ok = PortfolioAccountingService.call(okaz)
      assert_equal bd(30_000), core.cash, "source cash reduced by transfer"
      assert_equal bd(20_000), ok.cash, "destination cash increased by transfer"
      assert_equal bd(20_000), core.withdrawals, "transfer_out is a withdrawal for the source"
      assert_equal bd(20_000), ok.contributions, "transfer_in is a contribution for the destination"

      master = PortfolioMasterAccountingService.call([@portfolio, okaz])
      assert_equal bd(50_000), master.external_contributions, "only the real 50k contribution is external"
      assert_equal bd(0), master.external_withdrawals, "transfer is not an external withdrawal"
      assert_equal bd(20_000), master.internal_transfers
      assert_equal bd(50_000), master.nav, "Master NAV unchanged by an internal transfer"
    end
  end

  # TEST 8 — Base/Temporary buys never change contributions
  test "T8 base/temporary buys are internal, contributions unchanged" do
    b = buy!(100); b.update!(position_role: "base")
    t = buy!(40, on: Time.zone.local(2026, 2, 3)); t.update!(position_role: "temporary")
    r = result(holdings: 140)
    assert_equal bd(0), r.contributions, "buys add no external contribution"
  end
end
