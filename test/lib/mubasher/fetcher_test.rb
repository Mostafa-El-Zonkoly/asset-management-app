# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/mubasher/fetcher")

# Fixture-only tests for the stock price fetcher. No live network.
class Mubasher::FetcherTest < ActiveSupport::TestCase
  # Fetcher whose market data comes from a canned API payload instead of HTTP.
  class StubFetcher < Mubasher::Fetcher
    attr_reader :requests

    def initialize(payload)
      super()
      @payload = payload
      @requests = 0
    end

    private

    def load_market_rows(_country)
      @requests += 1
      self.class.index_rows(@payload)
    end
  end

  PAYLOAD = {
    "status" => 200,
    "data" => {
      "content" => [
        { "code" => "ABUK", "value" => "78.41", "previousClose" => "77.50", "updatedAt" => "2026-11-15 12:29:00" },
        { "code" => "AMOC", "value" => "13.47", "previousClose" => "13.04", "updatedAt" => "2026-11-15 12:29:00" },
        { "code" => "BAD", "value" => "-", "previousClose" => nil, "updatedAt" => nil }
      ],
      "isLast" => true
    }
  }.freeze

  setup { Mubasher::Fetcher.clear_cache! }
  teardown { Mubasher::Fetcher.clear_cache! }

  test "reads stock prices from the API payload by symbol" do
    f = StubFetcher.new(PAYLOAD)
    assert_in_delta 78.41, f.fetch_stock_price(symbol: "abuk")[:price], 1e-9
    assert_in_delta 13.47, f.fetch_stock_price(symbol: "AMOC")[:price], 1e-9
  end

  test "stock page URLs are routed to the API, not scraped" do
    f = StubFetcher.new(PAYLOAD)
    result = f.fetch_price_from_url(url: "https://www.mubasher.info/markets/EGX/stocks/ABUK")
    assert_in_delta 78.41, result[:price], 1e-9
    assert_equal "mubasher_api", result[:source]
  end

  test "one market request is shared across symbols (cached)" do
    f = StubFetcher.new(PAYLOAD)
    f.fetch_stock_price(symbol: "ABUK")
    f.fetch_stock_price(symbol: "AMOC")
    assert_equal 1, f.requests
  end

  test "unknown symbol or unparseable value raises instead of saving junk" do
    f = StubFetcher.new(PAYLOAD)
    assert_raises(Mubasher::FetchError) { f.fetch_stock_price(symbol: "NOPE") }
    assert_raises(Mubasher::FetchError) { f.fetch_stock_price(symbol: "BAD") }
  end

  # Regression: the SPA shell has no price; the old heuristics returned the `8`
  # from `<meta charset="utf-8">`.
  test "an empty SPA shell page raises rather than returning 8" do
    html = <<~HTML
      <!doctype html>
      <html lang="en-US"><head><meta charset="utf-8"><title>MubasherInfo</title>
      <meta name="viewport" content="width=device-width, initial-scale=1"></head>
      <body><app-root></app-root><script src="main-5ca1462c.js"></script></body></html>
    HTML
    assert_raises(Mubasher::FetchError) { Mubasher::Fetcher.new.extract_price(html: html) }
  end

  test "still extracts an anchored price from a server-rendered page" do
    html = <<~HTML
      <html><head><meta charset="utf-8"></head>
      <body><nav>Menu 1 2 3</nav><h1>Some Fund</h1>
      <div class="nav-value">12.3456</div></body></html>
    HTML
    assert_in_delta 12.3456, Mubasher::Fetcher.new.extract_price(html: html), 1e-9
  end
end
