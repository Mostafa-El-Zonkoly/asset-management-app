# frozen_string_literal: true

require "test_helper"

class PortfolioXirrServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  test "JUFO/VLMRA scenario matches Excel XIRR and sell uses full proceeds when total_amount is mis-stored as cost basis" do
    travel_to Time.zone.local(2026, 5, 1, 12, 0, 0) do
      suffix = SecureRandom.hex(4)
      egp = Currency.find_by!(code: "EGP")
      cat_stocks = Category.find_by!(name: "EGX Stocks")
      sector = Sector.find_by!(key: "financial")
      manual = PriceSource.find_by!(key: "manual")
      at_stock = AssetType.find_by!(key: "direct_stock")
      cat_cash = Category.find_by!(name: "Cash")
      at_wallet = AssetType.find_by!(key: "wallet")

      wallet = Asset.create!(
        code: "WX#{suffix[0...8]}",
        name: "XIRR #{suffix}",
        category: cat_cash,
        asset_type: at_wallet,
        currency: egp,
        active: true
      )
      jufo = Asset.create!(
        code: "JUF#{suffix[0...8]}",
        name: "Jufo Foods",
        category: cat_stocks,
        asset_type: at_stock,
        currency: egp,
        sector: sector,
        active: true
      )
      vlmra = Asset.create!(
        code: "VLR#{suffix[0...8]}",
        name: "V LMRA test",
        category: cat_stocks,
        asset_type: at_stock,
        currency: egp,
        sector: sector,
        active: true
      )

      TransactionProcessorService.call!(
        portfolio_id: nil,
        asset_id: wallet.id,
        transaction_type: "deposit",
        quantity: 1,
        total_amount: 250_000,
        currency_id: egp.id,
        date: Time.zone.local(2026, 4, 10, 9, 0, 0)
      )

      portfolio = Portfolio.create!(name: "XIRR JUFO scenario #{suffix}")

      TransactionProcessorService.call!(
        portfolio_id: portfolio.id,
        asset_id: jufo.id,
        transaction_type: "buy",
        quantity: 100,
        price_per_unit: BigDecimal("26.60"),
        total_amount: BigDecimal("2660"),
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 4, 13, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: portfolio.id,
        asset_id: vlmra.id,
        transaction_type: "buy",
        quantity: 149,
        price_per_unit: BigDecimal("32.40"),
        total_amount: BigDecimal("4827"),
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 4, 15, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: portfolio.id,
        asset_id: jufo.id,
        transaction_type: "sell",
        quantity: 100,
        price_per_unit: BigDecimal("28.41"),
        total_amount: BigDecimal("2841"),
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 4, 16, 9, 0, 0)
      )

      AssetPrice.create!(
        asset: vlmra,
        currency: egp,
        date: Date.new(2026, 4, 30),
        price: BigDecimal("33"),
        price_source: manual
      )

      expected_xirr = BigDecimal("220.75")

      assert_good_xirr(portfolio, expected_xirr)

      sell_tx = portfolio.portfolio_transactions.joins(:transaction_type).merge(TransactionType.where(key: "sell")).order(:date).first!
      # Simulate legacy rows: amounts column holds cost-of-shares-exited instead of proceeds; realised_gain is still correct.
      sell_tx.update_columns(total_amount: BigDecimal("2660"))

      bd = PortfolioXirrService.breakdown(portfolio)
      sell_flow = bd.flow_lines.find { |ln| ln.kind == "sell" }
      assert_equal BigDecimal("2841"), sell_flow.amount
      delta = (bd.result.annualized_percent - expected_xirr).abs
      assert delta < 5,
             "XIRR must use proceeds (~2841), not stored cost (~2660); got #{bd.result.annualized_percent}%"
    end
  end

  def assert_good_xirr(portfolio, expected_pct)
    bd = PortfolioXirrService.breakdown(portfolio)
    assert_not_nil bd.result.annualized_percent
    delta = (bd.result.annualized_percent - expected_pct).abs
    assert delta < 5, "expected XIRR≈#{expected_pct}% (±5), got #{bd.result.annualized_percent}%"
    sell_flow = bd.flow_lines.find { |ln| ln.kind == "sell" }
    assert_equal BigDecimal("2841"), sell_flow&.amount.to_d
  end
end
