# frozen_string_literal: true

require "test_helper"

class AssetDayPerformanceServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  test "change is day price minus latest prior price for same currency" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat_stocks = Category.find_by!(name: "EGX Stocks")
    sector = Sector.find_by!(key: "financial")
    manual = PriceSource.find_by!(key: "manual")
    at_stock = AssetType.find_by!(key: "direct_stock")

    asset = Asset.create!(
      code: "PD#{suffix[0...8]}",
      name: "Perf day test",
      category: cat_stocks,
      asset_type: at_stock,
      currency: egp,
      sector: sector,
      active: true
    )

    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 5), price: 10, price_source: manual)
    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 8), price: 12, price_source: manual)

    portfolio = Portfolio.create!(name: "Perf holdings #{suffix}")
    Holding.create!(portfolio: portfolio, asset: asset, quantity: 100)

    rows = AssetDayPerformanceService.call(range_begin: Date.new(2026, 5, 8), range_end: Date.new(2026, 5, 8))
    row = rows.find { |r| r.asset.id == asset.id }

    assert_equal BigDecimal("12"), row.day_price.price.to_d
    assert_equal Date.new(2026, 5, 5), row.prior_price.date
    assert_equal BigDecimal("2"), row.change
    assert_in_delta 20.0, row.change_pct.to_f, 0.0001
  end

  test "no change when day price missing but still listed when held" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat_stocks = Category.find_by!(name: "EGX Stocks")
    sector = Sector.find_by!(key: "financial")
    manual = PriceSource.find_by!(key: "manual")
    at_stock = AssetType.find_by!(key: "direct_stock")

    asset = Asset.create!(
      code: "PX#{suffix[0...8]}",
      name: "Perf missing day",
      category: cat_stocks,
      asset_type: at_stock,
      currency: egp,
      sector: sector,
      active: true
    )

    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 5), price: 10, price_source: manual)

    portfolio = Portfolio.create!(name: "Perf missing day #{suffix}")
    Holding.create!(portfolio: portfolio, asset: asset, quantity: 50)

    rows = AssetDayPerformanceService.call(range_begin: Date.new(2026, 5, 8), range_end: Date.new(2026, 5, 8))
    row = rows.find { |r| r.asset.id == asset.id }

    assert_nil row.day_price
    assert_equal BigDecimal("10"), row.prior_price.price.to_d
    assert_nil row.change
    assert_nil row.change_pct
  end

  test "excludes direct stocks with no holdings" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat_stocks = Category.find_by!(name: "EGX Stocks")
    sector = Sector.find_by!(key: "financial")
    manual = PriceSource.find_by!(key: "manual")
    at_stock = AssetType.find_by!(key: "direct_stock")

    asset = Asset.create!(
      code: "PN#{suffix[0...8]}",
      name: "Perf not held",
      category: cat_stocks,
      asset_type: at_stock,
      currency: egp,
      sector: sector,
      active: true
    )

    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 8), price: 99, price_source: manual)

    rows = AssetDayPerformanceService.call(range_begin: Date.new(2026, 5, 8), range_end: Date.new(2026, 5, 8))

    assert_nil rows.find { |r| r.asset.id == asset.id }
  end

  test "range uses latest quote inside window vs last quote before range start" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat_stocks = Category.find_by!(name: "EGX Stocks")
    sector = Sector.find_by!(key: "financial")
    manual = PriceSource.find_by!(key: "manual")
    at_stock = AssetType.find_by!(key: "direct_stock")

    asset = Asset.create!(
      code: "PR#{suffix[0...8]}",
      name: "Perf range test",
      category: cat_stocks,
      asset_type: at_stock,
      currency: egp,
      sector: sector,
      active: true
    )

    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 4, 30), price: 100, price_source: manual)
    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 7), price: 105, price_source: manual)
    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 9), price: 112, price_source: manual)

    portfolio = Portfolio.create!(name: "Perf range #{suffix}")
    Holding.create!(portfolio: portfolio, asset: asset, quantity: 10)

    rows = AssetDayPerformanceService.call(range_begin: Date.new(2026, 5, 6), range_end: Date.new(2026, 5, 10))
    row = rows.find { |r| r.asset.id == asset.id }

    assert_equal Date.new(2026, 4, 30), row.prior_price.date
    assert_equal BigDecimal("100"), row.prior_price.price.to_d
    assert_equal Date.new(2026, 5, 9), row.day_price.date
    assert_equal BigDecimal("112"), row.day_price.price.to_d
    assert_equal BigDecimal("12"), row.change
    assert_in_delta 12.0, row.change_pct.to_f, 0.0001
  end

  test "range_begin after range_end is normalized" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat_stocks = Category.find_by!(name: "EGX Stocks")
    sector = Sector.find_by!(key: "financial")
    manual = PriceSource.find_by!(key: "manual")
    at_stock = AssetType.find_by!(key: "direct_stock")

    asset = Asset.create!(
      code: "PS#{suffix[0...8]}",
      name: "Perf swap range",
      category: cat_stocks,
      asset_type: at_stock,
      currency: egp,
      sector: sector,
      active: true
    )

    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 5), price: 10, price_source: manual)
    AssetPrice.create!(asset: asset, currency: egp, date: Date.new(2026, 5, 8), price: 12, price_source: manual)

    portfolio = Portfolio.create!(name: "Perf swap #{suffix}")
    Holding.create!(portfolio: portfolio, asset: asset, quantity: 1)

    row_ordered = AssetDayPerformanceService.call(range_begin: Date.new(2026, 5, 6), range_end: Date.new(2026, 5, 10)).find { |r| r.asset.id == asset.id }
    row_swapped = AssetDayPerformanceService.call(range_begin: Date.new(2026, 5, 10), range_end: Date.new(2026, 5, 6)).find { |r| r.asset.id == asset.id }

    assert_equal row_ordered.change, row_swapped.change
    assert_equal row_ordered.day_price.date, row_swapped.day_price.date
    assert_equal row_ordered.prior_price.date, row_swapped.prior_price.date
  end
end
