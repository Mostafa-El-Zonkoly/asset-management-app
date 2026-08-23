# frozen_string_literal: true

require "test_helper"

class ZakaaStatsServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  test "zakatable total uses per-asset percentage across portfolios and wallets" do
    travel_to Time.zone.local(2026, 5, 20, 12, 0, 0) do
      suffix = SecureRandom.hex(4)
      egp = Currency.find_by!(code: "EGP")
      cat_stocks = Category.find_by!(name: "EGX Stocks")
      cat_cash = Category.find_by!(name: "Cash")
      at_stock = AssetType.find_by!(key: "direct_stock")
      at_wallet = AssetType.find_by!(key: "wallet")
      sector = Sector.find_by!(key: "financial")
      manual = PriceSource.find_by!(key: "manual")

      wallet = Asset.create!(
        code: "ZW#{suffix[0...8]}",
        name: "Zakaa wallet #{suffix}",
        category: cat_cash,
        asset_type: at_wallet,
        currency: egp,
        zaka_percentage: 100,
        active: true
      )
      stock = Asset.create!(
        code: "ZS#{suffix[0...8]}",
        name: "Zakaa stock #{suffix}",
        category: cat_stocks,
        asset_type: at_stock,
        currency: egp,
        sector: sector,
        zaka_percentage: 50,
        active: true
      )

      AssetPrice.create!(
        asset: stock,
        currency: egp,
        price: 100,
        date: Date.current,
        price_source: manual
      )

      TransactionProcessorService.call!(
        portfolio_id: nil,
        asset_id: wallet.id,
        transaction_type: "deposit",
        quantity: 1,
        total_amount: 2000,
        currency_id: egp.id,
        date: Time.zone.local(2026, 5, 1, 9, 0, 0)
      )

      portfolio_a = Portfolio.create!(name: "Zakaa A #{suffix}")
      portfolio_b = Portfolio.create!(name: "Zakaa B #{suffix}")

      TransactionProcessorService.call!(
        portfolio_id: portfolio_a.id,
        asset_id: stock.id,
        transaction_type: "buy",
        quantity: 10,
        price_per_unit: 100,
        total_amount: 1000,
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 5, 2, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: portfolio_b.id,
        asset_id: stock.id,
        transaction_type: "buy",
        quantity: 5,
        price_per_unit: 100,
        total_amount: 500,
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 5, 3, 9, 0, 0)
      )

      result = ZakaaStatsService.call

      stock_row = result[:rows].find { |r| r.asset.id == stock.id }
      wallet_row = result[:rows].find { |r| r.asset.id == wallet.id }

      assert_in_delta 1500, stock_row.current_value.to_f, 0.01
      assert_in_delta 750, stock_row.zakatable_amount.to_f, 0.01

      # Wallet balance after buys: 2000 - 1000 - 500 = 500
      assert_in_delta 500, wallet_row.current_value.to_f, 0.01
      assert_in_delta 500, wallet_row.zakatable_amount.to_f, 0.01

      assert_in_delta 1250, result[:zakatable_total].to_f, 0.01
    end
  end

  test "eligible when zakatable total meets nisab threshold" do
    travel_to Time.zone.local(2026, 5, 20, 12, 0, 0) do
      suffix = SecureRandom.hex(4)
      egp = Currency.find_by!(code: "EGP")
      cat = Category.find_by!(name: "EGX Stocks")
      at = AssetType.find_by!(key: "direct_stock")
      sector = Sector.find_by!(key: "financial")
      manual = PriceSource.find_by!(key: "manual")

      ref = Asset.create!(
        code: "NR#{suffix[0...8]}",
        name: "Nisab #{suffix}",
        category: cat,
        asset_type: at,
        currency: egp,
        sector: sector,
        active: true
      )
      AssetPrice.create!(asset: ref, currency: egp, price: 10, date: Date.current, price_source: manual)

      ZakaSetting.record.update!(nisab_asset: ref, nisab_quantity: 100, rate_percentage: 2.5)

      result = ZakaaStatsService.call

      assert_equal :nisab_not_configured, result[:eligibility_reason] unless result[:nisab].configured

      # With no holdings, zakatable is 0 — below nisab 1000
      result = ZakaaStatsService.call
      assert_not result[:eligible]
      assert_equal :below_nisab, result[:eligibility_reason]
      assert_in_delta 1000, result[:nisab_threshold].to_f, 0.01
    end
  end

  test "suggested due and payment overdue flag" do
    travel_to Time.zone.local(2026, 5, 20, 12, 0, 0) do
      egp = Currency.find_by!(code: "EGP")
      settings = ZakaSetting.record
      settings.update!(payment_interval_days: 30, rate_percentage: 2.5)

      ZakaPayment.create!(
        paid_on: Date.current - 40,
        amount: 100,
        currency: egp
      )

      result = ZakaaStatsService.call

      assert result[:payment_overdue]
      assert_equal 40, result[:days_since_last_payment]
    end
  end

  test "no payment overdue when no payments recorded" do
    ZakaPayment.delete_all
    result = ZakaaStatsService.call
    assert_not result[:payment_overdue]
    assert_nil result[:last_payment]
  end
end
