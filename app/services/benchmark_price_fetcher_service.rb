# frozen_string_literal: true

require Rails.root.join("lib/mubasher/index_rails_adapter")

# Fetches daily CLOSING levels for fetchable market indices (the EGX30 / EGX33
# Shariah benchmarks and any other index flagged is_active with a source URL) and
# upserts them into index_prices. Runs as part of the normal price-fetch sweep
# (see PriceFetcherService.fetch_all) so "fetch all prices" refreshes benchmarks
# exactly like assets — same trigger, same daily cadence, no separate job.
#
# Idempotent: IndexPrice is unique per [market_index_id, date] and the adapter
# upserts, so re-running never duplicates a trading-date snapshot.
class BenchmarkPriceFetcherService
  class << self
    def fetch_one(market_index, date: Date.current)
      record = adapter_for(market_index, date: date).fetch_and_persist!
      Rails.logger.info("BenchmarkPriceFetcherService: fetched #{market_index.code} => #{record.price} (#{date})")
      { ok: true, market_index_id: market_index.id, code: market_index.code, price: record.price, date: date }
    rescue Mubasher::FetchError => e
      Rails.logger.warn("BenchmarkPriceFetcherService: failed for #{market_index.code}: #{e.message}")
      { ok: false, market_index_id: market_index.id, code: market_index.code, error: e.message }
    rescue StandardError => e
      Rails.logger.error("BenchmarkPriceFetcherService: unexpected error for #{market_index.code}: #{e.class} - #{e.message}")
      { ok: false, market_index_id: market_index.id, code: market_index.code, error: "Unexpected error: #{e.message}" }
    end

    # Fetch every fetchable index. Yields per-index progress like the asset
    # fetcher so callers can drive the same status UI.
    def fetch_all(date: Date.current)
      indices = fetchable_indices
      results = []
      success = 0
      failed = 0

      indices.each_with_index do |mi, idx|
        results << fetch_one(mi, date: date)
        results.last[:ok] ? success += 1 : failed += 1
        yield({ current: idx + 1, total: indices.size, success: success, failed: failed, code: mi.code }) if block_given?
      end

      { ok: failed.zero?, total: indices.size, success: success, failed: failed, date: date, results: results }
    end

    # Current.user is nil in the public daily job, so the default scope does not
    # filter — every user's fetchable index is refreshed (ownership on the written
    # IndexPrice is derived from its parent index via tenant_through).
    def fetchable_indices
      MarketIndex.fetchable.includes(:currency).order(:code).to_a
    end

    private

    def adapter_for(market_index, date:)
      case market_index.source.to_s.strip.downcase
      when "", "mubasher"
        Mubasher::IndexRailsAdapter.new(market_index: market_index, date: date)
      else
        # Only Mubasher index scraping is implemented today; treat any other
        # source as Mubasher-style (the URL scraper) rather than silently skipping.
        Mubasher::IndexRailsAdapter.new(market_index: market_index, date: date)
      end
    end
  end
end
