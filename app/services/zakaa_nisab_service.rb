# frozen_string_literal: true

# Nisab threshold = nisab_quantity × latest price of reference asset (reporting currency).
class ZakaaNisabService
  Result = Struct.new(
    :configured,
    :threshold,
    :missing_price,
    keyword_init: true
  )

  class << self
    def call(settings: ZakaSetting.record, reporting_currency_id: Currency.reporting_currency_id)
      new(settings: settings, reporting_currency_id: reporting_currency_id).call
    end
  end

  def initialize(settings:, reporting_currency_id:)
    @settings = settings
    @reporting_currency_id = reporting_currency_id
  end

  def call
    unless @settings.nisab_configured?
      return Result.new(configured: false, threshold: nil, missing_price: false)
    end

    asset = @settings.nisab_asset
    price = latest_asset_price(asset)
    if price.nil? || price <= 0
      return Result.new(configured: true, threshold: nil, missing_price: true)
    end

    local = @settings.nisab_quantity.to_d * price
    threshold =
      if @reporting_currency_id.blank?
        local
      else
        CurrencyConversionService.convert(local, asset.currency_id, @reporting_currency_id)
      end

    Result.new(configured: true, threshold: threshold, missing_price: false)
  end

  private

  def latest_asset_price(asset)
    asset.asset_prices.where(currency_id: asset.currency_id).order(date: :desc).first&.price&.to_d
  end
end
