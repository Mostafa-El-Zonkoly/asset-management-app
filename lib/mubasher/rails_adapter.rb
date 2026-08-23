require_relative "fetcher"

module Mubasher
  # Rails adapter to upsert fetched prices into `asset.asset_prices`.
  #
  # Expected models:
  # - Asset has_many :asset_prices and belongs_to :currency
  # - AssetPrice has columns: date, price, currency_id, price_source_id
  # - PriceSource has a "scraped" key (will be created if missing)
  class RailsAdapter
    def initialize(asset:, date: Date.current, fetcher: Fetcher.new, default_price_source_key: "scraped")
      @asset = asset
      @date = date
      @fetcher = fetcher
      @default_price_source_key = default_price_source_key
    end

    def fetch_and_persist!
      raise Mubasher::FetchError, "asset currency is required" if @asset.currency_id.blank?

      payload = fetch_payload
      price_source = resolve_price_source(payload.fetch(:source))

      price_record = @asset.asset_prices.find_or_initialize_by(date: @date, currency_id: @asset.currency_id)
      price_record.price = payload.fetch(:price)
      price_record.price_source = price_source
      price_record.save!
      price_record
    rescue Mubasher::FetchError
      raise
    rescue StandardError => e
      raise Mubasher::FetchError, "Failed to persist fetched price: #{e.message}"
    end

    private

    def fetch_payload
      url = asset_price_url
      return @fetcher.fetch_price_from_url(url: url) if url.present?

      symbol = asset_symbol
      raise Mubasher::FetchError, "asset code/symbol is required" if symbol.blank?

      @fetcher.fetch_stock_price(symbol: symbol)
    end

    def asset_price_url
      return unless @asset.respond_to?(:price_url)

      @asset.price_url.to_s.strip.presence
    end

    def asset_symbol
      symbol = if @asset.respond_to?(:symbol)
                 @asset.symbol
               else
                 @asset.code
               end

      symbol.to_s.strip.presence
    end

    def resolve_price_source(_payload_source)
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
