# frozen_string_literal: true

require Rails.root.join("lib/mubasher/rails_adapter")
require Rails.root.join("lib/hermes/rails_adapter")
require Rails.root.join("lib/azimut/rails_adapter")

class PriceFetcherService
  class << self
    def fetch_one(asset, date: Date.current)
      record = adapter_for(asset, date: date).fetch_and_persist!

      Rails.logger.info("PriceFetcherService: fetched #{asset.code} => #{record.price} #{asset.currency.code} (#{date})")
      { ok: true, asset_id: asset.id, code: asset.code, price: record.price, date: date }
    rescue Mubasher::FetchError, Hermes::FetchError, Azimut::FetchError => e
      Rails.logger.warn("PriceFetcherService: failed for #{asset.code}: #{e.message}")
      { ok: false, asset_id: asset.id, code: asset.code, error: e.message }
    rescue StandardError => e
      Rails.logger.error("PriceFetcherService: unexpected error for #{asset.code}: #{e.class} - #{e.message}")
      { ok: false, asset_id: asset.id, code: asset.code, error: "Unexpected error: #{e.message}" }
    end

    def fetch_all(date: Date.current)
      assets = fetchable_assets
      results = []
      success = 0
      failed = 0

      assets.each_with_index do |asset, idx|
        results << fetch_one(asset, date: date)
        if results.last[:ok]
          success += 1
        else
          failed += 1
        end

        yield(
          {
            current: idx + 1,
            total: assets.size,
            success: success,
            failed: failed,
            asset_code: asset.code
          }
        ) if block_given?
      end

      {
        ok: failed.zero?,
        total: assets.size,
        success: success,
        failed: failed,
        date: date,
        results: results
      }
    end

    private

    def adapter_for(asset, date:)
      case asset.price_provider.to_s.strip.downcase
      when "hermes"
        Hermes::RailsAdapter.new(asset: asset, date: date)
      when "azimut"
        Azimut::RailsAdapter.new(asset: asset, date: date)
      else
        Mubasher::RailsAdapter.new(asset: asset, date: date)
      end
    end

    def fetchable_assets
      direct_stocks = Asset.active.direct_stock
      providered = Asset.active.where.not(price_provider: [nil, ""])

      Asset.where(id: direct_stocks.select(:id))
           .or(Asset.where(id: providered.select(:id)))
           .includes(:currency)
           .order(:code)
           .to_a
    end
  end
end
