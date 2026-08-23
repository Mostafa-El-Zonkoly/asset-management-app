# frozen_string_literal: true

require "faraday"
require "nokogiri"
require "time"
require_relative "fetch_error"

module Hermes
  # Fetches an IC Price from the EFG Holding mutual funds page.
  # The page is plain server-rendered HTML: each fund row has the fund
  # name in an <a> inside the first <td>, and the IC Price in the next <td>.
  #
  #   Hermes::Fetcher.new.fetch_fund_price(fund_name: "EFG Hermes Islamic Equity Fund")
  #   # => { price: 116.19, source: "hermes", fund_name: "...", url: "...", fetched_at: "..." }
  class Fetcher
    DEFAULT_URL = "https://efgholding.com/en/our-services/mutual-funds"

    DEFAULT_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "en"
    }.freeze

    DEFAULT_MAX_PRICE = 100_000.0

    def fetch_fund_price(fund_name:, url: nil, max_price: DEFAULT_MAX_PRICE)
      fund_name = fund_name.to_s.strip
      raise FetchError, "fund name is required" if fund_name.empty?

      page_url = url.to_s.strip.presence || DEFAULT_URL
      doc = load_page(page_url)

      row = find_row(doc, fund_name)
      raise FetchError, "Fund not found on Hermes page: #{fund_name}" unless row

      price_cell = row.css("td")[1] # td[0] = fund name, td[1] = IC Price
      raise FetchError, "Price cell missing for: #{fund_name}" unless price_cell

      price = normalize_price(price_cell.text)
      unless valid_price?(price, max_price: max_price)
        raise FetchError, "Could not extract a valid price for #{fund_name} (got: #{price_cell.text.strip.inspect})"
      end

      {
        price: price,
        source: "hermes",
        fund_name: fund_name,
        url: page_url,
        fetched_at: Time.now.utc.iso8601
      }
    end

    private

    def load_page(url)
      response = Faraday.get(url) do |req|
        DEFAULT_HEADERS.each { |k, v| req.headers[k] = v }
      end

      raise FetchError, "Hermes page returned status #{response.status}" unless response.success?

      Nokogiri::HTML(response.body.to_s)
    rescue Faraday::Error => e
      raise FetchError, "Failed to fetch Hermes page: #{e.message}"
    end

    def find_row(doc, fund_name)
      doc.css("tr").find do |tr|
        link = tr.at_css("a")
        link && link.text.strip.casecmp?(fund_name)
      end
    end

    def normalize_price(raw)
      token = raw.to_s.strip.tr(",", "").gsub(/[^\d.]/, "")
      return nil if token.empty? || token.count(".") > 1

      token.to_f
    end

    def valid_price?(value, max_price:)
      value && value.positive? && value <= max_price
    end
  end
end
