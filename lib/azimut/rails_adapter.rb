# frozen_string_literal: true

require_relative "fetcher"

module Azimut
  # Rails adapter to upsert Azimut fund NAVs into `asset.asset_prices`.
  #
  # Expects the asset to have:
  # - price_provider_key  => fund slug, e.g. "az-frs-alshryaa-1" (required unless link is set)
  # - price_provider_link => full API endpoint override (optional)
  class RailsAdapter
    def initialize(asset:, date: Date.current, fetcher: Fetcher.new, default_price_source_key: "scraped")
      @asset = asset
      @date = date
      @fetcher = fetcher
      @default_price_source_key = default_price_source_key
    end

    def fetch_and_persist!
      raise Azimut::FetchError, "asset currency is required" if @asset.currency_id.blank?

      fund_slug = @asset.price_provider_key.to_s.strip
      link = @asset.price_provider_link.to_s.strip.presence
      raise Azimut::FetchError, "price_provider_key (fund slug) is required for azimut" if fund_slug.empty? && link.nil?

      payload = @fetcher.fetch_fund_price(fund_slug: fund_slug, url: link)
      price_source = resolve_price_source

      price_record = @asset.asset_prices.find_or_initialize_by(date: @date, currency_id: @asset.currency_id)
      price_record.price = payload.fetch(:price)
      price_record.price_source = price_source
      price_record.save!
      price_record
    rescue Azimut::FetchError
      raise
    rescue StandardError => e
      raise Azimut::FetchError, "Failed to persist fetched price: #{e.message}"
    end

    private

    def resolve_price_source
      existing = PriceSource.find_by(key: @default_price_source_key)
      return existing if existing

      PriceSource.create!(
        key: @default_price_source_key,
        label: @default_price_source_key.humanize,
        position: PriceSource.maximum(:position).to_i + 1,
        active: true
      )
    end
  end
end
