# frozen_string_literal: true

require "test_helper"

class ZakaaNisabServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  test "returns not configured when nisab asset or quantity missing" do
    settings = ZakaSetting.record
    settings.update!(nisab_asset_id: nil, nisab_quantity: nil)

    result = ZakaaNisabService.call(settings: settings)

    assert_not result.configured
    assert_nil result.threshold
    assert_not result.missing_price
  end

  test "computes threshold from quantity times latest price in reporting currency" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat = Category.find_by!(name: "EGX Stocks")
    at = AssetType.find_by!(key: "direct_stock")
    sector = Sector.find_by!(key: "financial")
    manual = PriceSource.find_by!(key: "manual")

    ref_asset = Asset.create!(
      code: "REF#{suffix[0...8]}",
      name: "Nisab ref #{suffix}",
      category: cat,
      asset_type: at,
      currency: egp,
      sector: sector,
      active: true
    )
    AssetPrice.create!(
      asset: ref_asset,
      currency: egp,
      price: 100,
      date: Date.current,
      price_source: manual
    )

    settings = ZakaSetting.record
    settings.update!(nisab_asset: ref_asset, nisab_quantity: 10)

    result = ZakaaNisabService.call(settings: settings)

    assert result.configured
    assert_not result.missing_price
    assert_in_delta 1000, result.threshold.to_f, 0.01
  end

  test "flags missing price when reference asset has no price" do
    suffix = SecureRandom.hex(4)
    egp = Currency.find_by!(code: "EGP")
    cat = Category.find_by!(name: "EGX Stocks")
    at = AssetType.find_by!(key: "direct_stock")
    sector = Sector.find_by!(key: "financial")

    ref_asset = Asset.create!(
      code: "NP#{suffix[0...8]}",
      name: "No price #{suffix}",
      category: cat,
      asset_type: at,
      currency: egp,
      sector: sector,
      active: true
    )

    settings = ZakaSetting.record
    settings.update!(nisab_asset: ref_asset, nisab_quantity: 10)

    result = ZakaaNisabService.call(settings: settings)

    assert result.configured
    assert result.missing_price
    assert_nil result.threshold
  end
end
