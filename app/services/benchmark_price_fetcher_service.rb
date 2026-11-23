# frozen_string_literal: true

require Rails.root.join("lib/mubasher/index_rails_adapter")
require Rails.root.join("lib/yahoo_finance/index_rails_adapter")

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
    def fetch_one(market_index, date: Date.current, run_id: SecureRandom.uuid)
      provider = yahoo_benchmark?(market_index) ? "yahoo_finance" : "mubasher"
      fields = { run_id: run_id, provider: provider, market_index_id: market_index.id,
                 code: market_index.code, user_id: market_index.user_id, date: date }
      adapter = if provider == "yahoo_finance"
                  YahooFinance::IndexRailsAdapter.new(market_index: market_index, date: date)
                else
                  Mubasher::IndexRailsAdapter.new(market_index: market_index, date: date)
                end
      record = adapter.fetch_and_persist!
      log(:info, "index_saved", **fields, level: record.price, source_url: adapter.respond_to?(:fetched_url) ? adapter.fetched_url : nil)
      { ok: true, market_index_id: market_index.id, code: market_index.code, price: record.price, date: date }
    rescue Mubasher::FetchError, YahooFinance::FetchError => e
      log(:warn, "index_failed", **fields, reason: e.message)
      { ok: false, market_index_id: market_index.id, code: market_index.code, error: e.message }
    rescue StandardError => e
      log(:error, "index_failed", **fields, error_class: e.class.name)
      { ok: false, market_index_id: market_index.id, code: market_index.code, error: "Unexpected error: #{e.message}" }
    end

    # Fetch every fetchable index. Yields per-index progress like the asset
    # fetcher so callers can drive the same status UI.
    def fetch_all(date: Date.current, run_id: SecureRandom.uuid, indices: fetchable_indices)
      results = []
      success = 0
      failed = 0

      indices.each_with_index do |mi, idx|
        results << fetch_one(mi, date: date, run_id: run_id)
        results.last[:ok] ? success += 1 : failed += 1
        yield({ current: idx + 1, total: indices.size, success: success, failed: failed, code: mi.code }) if block_given?
      end

      { ok: failed.zero?, total: indices.size, success: success, failed: failed, date: date, results: results }
    end

    # Current.user is nil in the public daily job, so the default scope does not
    # filter — every user's fetchable index is refreshed (ownership on the written
    # IndexPrice is derived from its parent index via tenant_through).
    def fetchable_indices
      yahoo_indices = MarketIndex.where(is_benchmark: true, is_active: true)
                                 .where("UPPER(TRIM(code)) IN (?)", YahooFinance::IndexRailsAdapter::SYMBOLS.keys)
      MarketIndex.fetchable.or(yahoo_indices).includes(:currency).order(:code).to_a
    end

    private

    def log(severity, event, **fields)
      Rails.logger.public_send(severity, { job: "price_fetch", event: event, **fields }.to_json)
    end

    def yahoo_benchmark?(index)
      index.is_benchmark? && YahooFinance::IndexRailsAdapter::SYMBOLS.key?(index.code.to_s.strip.upcase)
    end
  end
end
