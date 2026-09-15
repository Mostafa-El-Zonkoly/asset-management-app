require_relative "index_fetcher"

module Mubasher
  # Persists a fetched index CLOSING level into `market_index.index_prices` for a
  # date. Idempotent per [market_index_id, date] (upsert), mirroring how the asset
  # adapter writes asset_prices — so re-running the daily fetch never creates a
  # duplicate snapshot for a trading date.
  class IndexRailsAdapter
    def initialize(market_index:, date: Date.current, fetcher: IndexFetcher.new, default_price_source_key: "scraped")
      @market_index = market_index
      @date = date
      @fetcher = fetcher
      @default_price_source_key = default_price_source_key
    end

    def fetch_and_persist!
      url = @market_index.fetch_url.to_s.strip
      raise Mubasher::FetchError, "index fetch_code or source_identifier (URL) is required" if url.empty?

      payload = @fetcher.fetch_level_from_url(url: url)
      price_source = resolve_price_source

      record = @market_index.index_prices.find_or_initialize_by(date: @date)
      record.price = payload.fetch(:level)
      record.price_source = price_source
      record.save!
      record
    rescue Mubasher::FetchError
      raise
    rescue StandardError => e
      raise Mubasher::FetchError, "Failed to persist fetched index level: #{e.message}"
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
