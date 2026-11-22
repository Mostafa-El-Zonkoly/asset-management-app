# frozen_string_literal: true

require Rails.root.join("lib/mubasher/rails_adapter")
require Rails.root.join("lib/hermes/rails_adapter")
require Rails.root.join("lib/azimut/rails_adapter")
require Rails.root.join("lib/efg/rails_adapter")

class PriceFetcherService
  class << self
    def fetch_one(asset, date: Date.current, run_id: SecureRandom.uuid)
      fields = { asset_id: asset.id, code: asset.code, user_id: asset.user_id, date: date }
      if efg_eligible?(asset)
        provider = "efg"
        begin
          record = Efg::RailsAdapter.new(asset: asset, date: date).fetch_and_persist!
        rescue Efg::FetchError => e
          log(:warn, run_id, "provider_fallback", **fields, provider: provider, fallback_provider: "mubasher",
              error_class: e.class.name, reason: e.message)
        end
      end

      unless record
        adapter = adapter_for(asset, date: date)
        provider = adapter.class.module_parent.name.downcase
        record = adapter.fetch_and_persist!
      end

      log(:info, run_id, "asset_saved", **fields, provider: provider, price: record.price, currency: asset.currency.code)
      { ok: true, asset_id: asset.id, code: asset.code, price: record.price, date: date, source: provider }
    rescue Mubasher::FetchError, Hermes::FetchError, Azimut::FetchError, Efg::FetchError => e
      log(:warn, run_id, "asset_failed", **fields, provider: provider, reason: e.message)
      { ok: false, asset_id: asset.id, code: asset.code, error: e.message }
    rescue StandardError => e
      log(:error, run_id, "asset_failed", **fields, provider: provider, error_class: e.class.name)
      { ok: false, asset_id: asset.id, code: asset.code, error: "Unexpected error: #{e.message}" }
    end

    def fetch_all(date: Date.current, run_id: SecureRandom.uuid)
      assets = fetchable_assets
      indices = BenchmarkPriceFetcherService.fetchable_indices
      total = assets.size + indices.size
      log(:info, run_id, "started", date: date, user_id: Current.user&.id,
          total: total, assets: assets.size, indices: indices.size)
      results = []
      success = 0
      failed = 0
      current = 0

      assets.each do |asset|
        results << fetch_one(asset, date: date, run_id: run_id)
        current += 1
        results.last[:ok] ? success += 1 : failed += 1
        yield({ current: current, total: total, success: success, failed: failed, asset_code: asset.code }) if block_given?
      end

      # Benchmarks (EGX30, EGX33 Shariah, …) refresh in the SAME sweep, so the
      # existing "fetch all prices" trigger and daily public job keep them current
      # alongside assets. They never touch asset_prices or portfolio accounting.
      index_results = []
      indices.each do |mi|
        r = BenchmarkPriceFetcherService.fetch_one(mi, date: date, run_id: run_id)
        index_results << r
        current += 1
        r[:ok] ? success += 1 : failed += 1
        yield({ current: current, total: total, success: success, failed: failed, asset_code: "#{mi.code} (index)" }) if block_given?
      end

      log(:info, run_id, "finished", date: date, total: total, updated: success, failed: failed)
      {
        ok: failed.zero?,
        total: total,
        success: success,
        failed: failed,
        date: date,
        results: results,
        index_results: index_results
      }
    rescue StandardError => e
      log(:error, run_id, "failed", date: date, error_class: e.class.name)
      raise
    end

    private

    def log(severity, run_id, event, **fields)
      Rails.logger.public_send(severity, { job: "price_fetch", run_id: run_id, event: event, **fields }.to_json)
    end

    def efg_eligible?(asset)
      asset.price_provider.blank? &&
        asset.direct_stock? &&
        asset.currency&.code.to_s.upcase == "EGP" &&
        EfgCredential.configured?
    end

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
           .includes(:currency, :asset_type)
           .order(:code)
           .to_a
    end
  end
end
