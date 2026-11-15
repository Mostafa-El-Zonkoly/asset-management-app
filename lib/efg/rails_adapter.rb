# frozen_string_literal: true

require_relative "client"

module Efg
  # Upserts today's EFG last-traded price into `asset.asset_prices`, using the
  # credentials stored (encrypted) in EfgCredential. The asset code is the EGX symbol.
  class RailsAdapter
    PRICE_SOURCE_KEY = "efg_api"

    def initialize(asset:, date: Date.current, client: nil)
      @asset = asset
      @date = date
      @client = client
    end

    def fetch_and_persist!
      raise Efg::FetchError, "asset currency is required" if @asset.currency_id.blank?

      payload = client.price(@asset.code)
      record = @asset.asset_prices.find_or_initialize_by(date: @date, currency_id: @asset.currency_id)
      record.price = payload.fetch(:price)
      record.price_source = price_source
      record.save!
      record
    rescue Efg::FetchError
      raise
    rescue StandardError => e
      raise Efg::FetchError, "Failed to persist EFG price: #{e.class}"
    end

    private

    def client
      @client ||= EfgCredential.client || raise(Efg::FetchError, "EFG credentials are not configured")
    end

    def price_source
      PriceSource.find_by(key: PRICE_SOURCE_KEY) || PriceSource.create!(
        key: PRICE_SOURCE_KEY,
        label: "EFG API",
        position: PriceSource.maximum(:position).to_i + 1,
        active: true
      )
    end
  end
end
