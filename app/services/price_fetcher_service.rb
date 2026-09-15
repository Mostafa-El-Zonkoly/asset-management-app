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
      indices = BenchmarkPriceFetcherService.fetchable_indices
      total = assets.size + indices.size
      results = []
      success = 0
      failed = 0
      current = 0

      assets.each do |asset|
        results << fetch_one(asset, date: date)
        current += 1
        results.last[:ok] ? success += 1 : failed += 1
        yield({ current: current, total: total, success: success, failed: failed, asset_code: asset.code }) if block_given?
      end

      # Benchmarks (EGX30, EGX33 Shariah, …) refresh in the SAME sweep, so the
      # existing "fetch all prices" trigger and daily public job keep them current
      # alongside assets. They never touch asset_prices or portfolio accounting.
      index_results = []
      indices.each do |mi|
        r = BenchmarkPriceFetcherService.fetch_one(mi, date: date)
        index_results << r
        current += 1
        r[:ok] ? success += 1 : failed += 1
        yield({ current: current, total: total, success: success, failed: failed, asset_code: "#{mi.code} (index)" }) if block_given?
      end

      {
        ok: failed.zero?,
        total: total,
        success: success,
        failed: failed,
        date: date,
        results: results,
        index_results: index_results
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
