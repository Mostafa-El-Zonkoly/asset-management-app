# frozen_string_literal: true

require_relative "fetcher"

module Hermes
  # Rails adapter to upsert Hermes (EFG Holding) fund prices into `asset.asset_prices`.
  #
  # Expects the asset to have:
  # - price_provider_key  => fund name as shown on the EFG page (required)
  # - price_provider_link => page URL (optional, defaults to Fetcher::DEFAULT_URL)
  class RailsAdapter
    def initialize(asset:, date: Date.current, fetcher: Fetcher.new, default_price_source_key: "scraped")
      @asset = asset
      @date = date
      @fetcher = fetcher
      @default_price_source_key = default_price_source_key
    end

    def fetch_and_persist!
      raise Hermes::FetchError, "asset currency is required" if @asset.currency_id.blank?

      fund_name = @asset.price_provider_key.to_s.strip
      raise Hermes::FetchError, "price_provider_key (fund name) is required for hermes" if fund_name.empty?

      payload = @fetcher.fetch_fund_price(
        fund_name: fund_name,
        url: @asset.price_provider_link.to_s.strip.presence
      )
      price_source = resolve_price_source

      price_record = @asset.asset_prices.find_or_initialize_by(date: @date, currency_id: @asset.currency_id)
      price_record.price = payload.fetch(:price)
      price_record.price_source = price_source
      price_record.save!
      price_record
    rescue Hermes::FetchError
      raise
    rescue StandardError => e
      raise Hermes::FetchError, "Failed to persist fetched price: #{e.message}"
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
