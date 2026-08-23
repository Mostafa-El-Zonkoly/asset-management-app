# frozen_string_literal: true

require "faraday"
require "json"
require "time"
require_relative "fetch_error"

module Azimut
  # Fetches a fund NAV from the Azimut Egypt JSON API.
  #
  #   Azimut::Fetcher.new.fetch_fund_price(fund_slug: "az-frs-alshryaa-1")
  #   # => { price: 1.83875, source: "azimut", fund_slug: "...", nav_date: "June 10, 2026", url: "...", fetched_at: "..." }
  class Fetcher
    BASE_URL = "https://api.azimut.eg"

    DEFAULT_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      "Accept" => "application/json"
    }.freeze

    DEFAULT_MAX_PRICE = 100_000.0

    # fund_slug: e.g. "az-frs-alshryaa-1"
    # url: optional full endpoint override; defaults to BASE_URL/api/list/funds/<slug>
    def fetch_fund_price(fund_slug:, url: nil, max_price: DEFAULT_MAX_PRICE)
      fund_slug = fund_slug.to_s.strip
      endpoint = url.to_s.strip.presence || begin
        raise FetchError, "fund slug is required" if fund_slug.empty?

        "#{BASE_URL}/api/list/funds/#{fund_slug}"
      end

      payload = load_json(endpoint)
      nav = payload.dig("data", "last_nav", "nav")
      raise FetchError, "NAV missing in Azimut response for #{fund_slug.presence || endpoint}" if nav.nil?

      price = nav.to_f
      unless valid_price?(price, max_price: max_price)
        raise FetchError, "Invalid NAV from Azimut for #{fund_slug.presence || endpoint}: #{nav.inspect}"
      end

      {
        price: price,
        source: "azimut",
        fund_slug: fund_slug,
        nav_date: payload.dig("data", "last_nav", "date"),
        url: endpoint,
        fetched_at: Time.now.utc.iso8601
      }
    end

    private

    def load_json(url)
      response = Faraday.get(url) do |req|
        DEFAULT_HEADERS.each { |k, v| req.headers[k] = v }
      end

      raise FetchError, "Azimut API returned status #{response.status}" unless response.success?

      JSON.parse(response.body.to_s)
    rescue Faraday::Error => e
      raise FetchError, "Failed to fetch Azimut API: #{e.message}"
    rescue JSON::ParserError => e
      raise FetchError, "Azimut response was not JSON (check the fund slug, or leave the link blank to use the API): #{e.message}"
    end

    def valid_price?(value, max_price:)
      value && value.positive? && value <= max_price
    end
  end
end
