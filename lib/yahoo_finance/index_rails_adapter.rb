# frozen_string_literal: true

require "date"
require "faraday"
require "nokogiri"
require "uri"

module YahooFinance
  class FetchError < StandardError; end

  class IndexRailsAdapter
    SYMBOLS = { "EGX30" => "^CASE30", "EGX33" => "^SHARIAH.CA" }.freeze

    attr_reader :fetched_url

    def initialize(market_index:, date:)
      @market_index = market_index
      @date = date
      @symbol = SYMBOLS.fetch(market_index.code.to_s.strip.upcase)
      @fetched_url = "https://finance.yahoo.com/quote/#{URI.encode_www_form_component(@symbol)}/history/"
    end

    def fetch_and_persist!
      cairo_now = Time.current.in_time_zone("Africa/Cairo")
      if @date > cairo_now.to_date || (@date == cairo_now.to_date && cairo_now.hour < 15)
        raise FetchError, "Yahoo Finance daily close can be fetched after 15:00 Cairo time"
      end

      response = Faraday.get(fetched_url) do |request|
        request.headers["Accept"] = "text/html"
        request.headers["Accept-Language"] = "en-US,en;q=0.9"
        request.options.open_timeout = 5
        request.options.timeout = 10
      end
      raise FetchError, "Yahoo Finance returned HTTP #{response.status} for #{@symbol}" unless response.success?

      level = self.class.extract_close(response.body, date: @date)
      raise FetchError, "No Yahoo Finance close for #{@symbol} on #{@date}" unless level

      source = PriceSource.find_by(key: "yahoo_finance")
      unless source
        PriceSource.insert_all(
          [{ key: "yahoo_finance", label: "Yahoo Finance", position: PriceSource.maximum(:position).to_i + 1, active: true }],
          unique_by: :key
        )
        source = PriceSource.find_by!(key: "yahoo_finance")
      end

      IndexPrice.upsert(
        { market_index_id: @market_index.id, user_id: @market_index.user_id, date: @date, price: level, price_source_id: source.id },
        unique_by: %i[market_index_id date], update_only: %i[price price_source_id]
      )
      @market_index.index_prices.find_by!(date: @date)
    rescue Faraday::Error => e
      raise FetchError, "Yahoo Finance request failed for #{@symbol} (#{e.class.name})"
    end

    def self.extract_close(html, date:)
      Nokogiri::HTML(html.to_s).css("table").each do |table|
        headers = table.css("thead th").map { |header| header.text.strip }
        date_column = headers.index("Date")
        close_column = headers.index { |header| header.match?(/\AClose(?:\b|\s)/) }
        next unless date_column && close_column

        table.css("tbody tr").each do |row|
          cells = row.css("td")
          next unless cells[date_column]&.text&.strip == date.strftime("%b %-d, %Y")

          value = Float(cells[close_column]&.text&.strip&.delete(","), exception: false)
          return value if value&.finite? && value.positive?
        end
      end

      nil
    end
  end
end
