# frozen_string_literal: true

require "test_helper"

class MonthlyCashFlowServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  test "aggregates deposits, withdrawals, and per-portfolio buy/sell by month in reporting currency" do
    travel_to Time.zone.local(2026, 5, 16, 12, 0, 0) do
      suffix = SecureRandom.hex(4)
      egp = Currency.find_by!(code: "EGP")
      cat_stocks = Category.find_by!(name: "EGX Stocks")
      cat_cash = Category.find_by!(name: "Cash")
      at_stock = AssetType.find_by!(key: "direct_stock")
      at_wallet = AssetType.find_by!(key: "wallet")
      sector = Sector.find_by!(key: "financial")

      wallet = Asset.create!(
        code: "MF#{suffix[0...8]}",
        name: "Monthly flow wallet #{suffix}",
        category: cat_cash,
        asset_type: at_wallet,
        currency: egp,
        active: true
      )
      stock = Asset.create!(
        code: "ST#{suffix[0...8]}",
        name: "Monthly flow stock #{suffix}",
        category: cat_stocks,
        asset_type: at_stock,
        currency: egp,
        sector: sector,
        active: true
      )

      portfolio_a = Portfolio.create!(name: "Flow A #{suffix}")
      portfolio_b = Portfolio.create!(name: "Flow B #{suffix}")

      TransactionProcessorService.call!(
        portfolio_id: nil,
        asset_id: wallet.id,
        transaction_type: "deposit",
        quantity: 1,
        total_amount: 10_000,
        currency_id: egp.id,
        date: Time.zone.local(2026, 4, 5, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: nil,
        asset_id: wallet.id,
        transaction_type: "withdrawal",
        quantity: 1,
        total_amount: 500,
        currency_id: egp.id,
        date: Time.zone.local(2026, 4, 20, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: portfolio_a.id,
        asset_id: stock.id,
        transaction_type: "buy",
        quantity: 10,
        price_per_unit: 100,
        total_amount: 1000,
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 4, 10, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: portfolio_b.id,
        asset_id: stock.id,
        transaction_type: "buy",
        quantity: 5,
        price_per_unit: 200,
        total_amount: 1000,
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 4, 12, 9, 0, 0)
      )

      TransactionProcessorService.call!(
        portfolio_id: portfolio_a.id,
        asset_id: stock.id,
        transaction_type: "sell",
        quantity: 2,
        price_per_unit: 110,
        total_amount: 200,
        currency_id: egp.id,
        related_wallet_id: wallet.id,
        date: Time.zone.local(2026, 4, 25, 9, 0, 0),
        realised_gain: 20
      )

      TransactionProcessorService.call!(
        portfolio_id: nil,
        asset_id: wallet.id,
        transaction_type: "deposit",
        quantity: 1,
        total_amount: 2000,
        currency_id: egp.id,
        date: Time.zone.local(2026, 5, 3, 9, 0, 0)
      )

      report = MonthlyCashFlowService.call
      april = report.months.find { |m| m.month == Date.new(2026, 4, 1) }
      may = report.months.find { |m| m.month == Date.new(2026, 5, 1) }

      assert april
      assert_equal BigDecimal("10000"), april.deposits
      assert_equal BigDecimal("500"), april.withdrawals
      assert_equal BigDecimal("1780"), april.net_investment

      row_a = april.portfolios.find { |r| r.portfolio_id == portfolio_a.id }
      row_b = april.portfolios.find { |r| r.portfolio_id == portfolio_b.id }
      assert_equal BigDecimal("1000"), row_a.buys
      assert_equal BigDecimal("220"), row_a.sells
      assert_equal BigDecimal("780"), row_a.net
      assert_equal BigDecimal("1000"), row_b.buys
      assert_equal BigDecimal("0"), row_b.sells

      assert may
      assert_equal BigDecimal("2000"), may.deposits
      assert_equal BigDecimal("0"), may.withdrawals
      assert_equal BigDecimal("0"), may.net_investment
    end
  end
end
