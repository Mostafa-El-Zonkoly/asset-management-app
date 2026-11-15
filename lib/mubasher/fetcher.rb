require "faraday"
require "json"
require "nokogiri"
require "time"
require "date"

module Mubasher
  class FetchError < StandardError; end

  # Fetches current prices from Mubasher.
  #
  # Stocks: Mubasher's site is now a JavaScript single-page app, so the old
  # `/markets/EGX/stocks/<SYMBOL>` page returns the same empty HTML shell for
  # every symbol. The previous HTML heuristics then fell through to "first number
  # in the page" and picked the `8` from `<meta charset="utf-8">`, saving 8.00 as
  # the price of every stock. Stock prices now come from the JSON endpoint the SPA
  # itself uses (one call returns the whole market), cached briefly so a
  # fetch-all sweep makes one request per market rather than one per asset.
  #
  # Other Mubasher URLs (e.g. fund pages) are still scraped, but only with
  # anchored extraction (JSON-LD, price-specific elements, a keyword next to the
  # number in the visible text). If none match we raise FetchError instead of
  # guessing — a failed fetch is visible; a silently wrong price is not.
  class Fetcher
    BASE_URL = "https://www.mubasher.info".freeze
    DAILY_PRICES_PATH = "/api/v1/stock-prices/daily".freeze

    DEFAULT_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9,ar;q=0.8"
    }.freeze

    JSON_HEADERS = DEFAULT_HEADERS.merge("Accept" => "application/json, text/plain, */*").freeze

    # Mubasher market code (as used in its URLs) => countryCode for the API.
    MARKET_COUNTRY_CODES = {
      "EGX" => "eg",
      "TDWL" => "sa",
      "DFM" => "ae",
      "ADX" => "ae",
      "KSE" => "kw",
      "BK" => "kw",
      "QE" => "qa",
      "BB" => "bh",
      "MSM" => "om"
    }.freeze

    STOCK_URL_PATTERN = %r{mubasher\.info/markets/([A-Za-z]+)/stocks/([A-Za-z0-9.\-]+)}i

    DEFAULT_MAX_PRICE = 100_000.0
    PAGE_SIZE = 1000
    CACHE_TTL = 300 # seconds

    @market_cache = {}
    @cache_mutex = Mutex.new

    class << self
      attr_reader :market_cache, :cache_mutex

      def clear_cache!
        cache_mutex.synchronize { market_cache.clear }
      end
    end

    # Fetch by market symbol, e.g. "ABUK"
    def fetch_stock_price(symbol:, market: "EGX", max_price: DEFAULT_MAX_PRICE)
      symbol = symbol.to_s.upcase.strip
      market = market.to_s.upcase.strip
      raise FetchError, "symbol is required" if symbol.empty?

      row = market_rows(market)[symbol]
      raise FetchError, "#{symbol} not found in Mubasher #{market} daily prices" if row.nil?

      price = parse_number(row["value"])
      unless valid_price?(price, max_price: max_price)
        raise FetchError, "Mubasher returned an invalid price for #{symbol}: #{row['value'].inspect}"
      end

      {
        price: price,
        previous_close: parse_number(row["previousClose"]),
        quoted_at: row["updatedAt"],
        source: "mubasher_api",
        symbol: symbol,
        market: market,
        fetched_at: Time.now.utc.iso8601,
        url: "#{BASE_URL}/markets/#{market}/stocks/#{symbol}"
      }
    end

    # Fetch from a full Mubasher URL. Stock pages are routed to the JSON API;
    # anything else is scraped with strict extraction.
    def fetch_price_from_url(url:, max_price: DEFAULT_MAX_PRICE)
      raise FetchError, "url is required" if url.to_s.strip.empty?
      raise FetchError, "url must include mubasher.info" unless url.include?("mubasher.info")

      if (m = url.match(STOCK_URL_PATTERN))
        return fetch_stock_price(symbol: m[2], market: m[1], max_price: max_price).merge(url: url)
      end

      response = http_get(url, headers: DEFAULT_HEADERS)
      html = response.body.to_s
      price = extract_price(html: html, max_price: max_price)

      {
        price: price,
        source: "mubasher_url",
        fetched_at: Time.now.utc.iso8601,
        url: url
      }
    rescue Nokogiri::XML::SyntaxError => e
      raise FetchError, "Failed to parse Mubasher HTML: #{e.message}"
    end

    # Public for unit tests: extract a price from page HTML, or raise FetchError.
    def extract_price(html:, max_price: DEFAULT_MAX_PRICE)
      doc = Nokogiri::HTML(html.to_s)
      doc.css("script:not([type='application/ld+json']), style, noscript, head meta, head title, head link").remove

      candidates = []
      candidates.concat(json_ld_candidates(doc))
      candidates.concat(css_candidates(doc))
      candidates.concat(keyword_candidates(doc))

      candidates.each do |candidate|
        numeric = normalize_price(candidate)
        return numeric if valid_price?(numeric, max_price: max_price)
      end

      raise FetchError, "Could not extract a valid price from Mubasher page. Structure may have changed."
    end

    # Public for unit tests: index API rows by symbol.
    def self.index_rows(payload)
      rows = payload.is_a?(Hash) ? payload.dig("data", "content") : nil
      raise FetchError, "Unexpected Mubasher API response shape" unless rows.is_a?(Array)

      rows.each_with_object({}) do |row, acc|
        code = row["code"].to_s.upcase.strip
        acc[code] = row unless code.empty?
      end
    end

    private

    def market_rows(market)
      country = MARKET_COUNTRY_CODES[market]
      raise FetchError, "Unsupported Mubasher market: #{market}" if country.nil?

      cache = Fetcher.market_cache
      Fetcher.cache_mutex.synchronize do
        entry = cache[country]
        return entry[:rows] if entry && (monotonic_now - entry[:at]) < CACHE_TTL
      end

      rows = load_market_rows(country)
      Fetcher.cache_mutex.synchronize { cache[country] = { rows: rows, at: monotonic_now } }
      rows
    end

    def load_market_rows(country)
      rows = {}
      page = 0
      loop do
        url = "#{BASE_URL}#{DAILY_PRICES_PATH}?countryCode=#{country}&page=#{page}&size=#{PAGE_SIZE}"
        response = http_get(url, headers: JSON_HEADERS)
        begin
          payload = JSON.parse(response.body.to_s)
        rescue JSON::ParserError => e
          raise FetchError, "Mubasher API returned non-JSON: #{e.message}"
        end

        rows.merge!(self.class.index_rows(payload))
        data = payload["data"] || {}
        break if data["isLast"] != false || page >= 20

        page += 1
      end
      raise FetchError, "Mubasher API returned no prices for #{country}" if rows.empty?

      rows
    end

    def http_get(url, headers:)
      response = Faraday.get(url) do |req|
        headers.each { |k, v| req.headers[k] = v }
        req.options.timeout = 20
        req.options.open_timeout = 10
      end
      raise FetchError, "Mubasher returned status #{response.status}" unless response.success?

      response
    rescue Faraday::Error => e
      raise FetchError, "Mubasher request failed: #{e.message}"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def json_ld_candidates(doc)
      doc.css('script[type="application/ld+json"]').flat_map do |script|
        payload = JSON.parse(script.text)
        find_price_fields(payload)
      rescue JSON::ParserError
        []
      end
    end

    # Only values under price-like keys — not every number in the JSON-LD.
    PRICE_KEYS = %w[price lowprice highprice nav lastprice last close currentprice value].freeze

    def find_price_fields(value)
      case value
      when Hash
        value.flat_map do |k, v|
          if PRICE_KEYS.include?(k.to_s.downcase.delete("_")) && (v.is_a?(Numeric) || v.is_a?(String))
            [v.to_s]
          else
            find_price_fields(v)
          end
        end
      when Array
        value.flat_map { |v| find_price_fields(v) }
      else
        []
      end
    end

    def css_candidates(doc)
      selectors = [
        ".stock-price",
        ".current-price",
        ".nav-value",
        ".market-summary__last-price",
        '[class*="last-price"]',
        '[class*="price"]',
        '[id*="price"]'
      ]

      selectors.flat_map do |selector|
        doc.css(selector).flat_map { |node| extract_numbers_from_text(node.text.to_s).first(1) }
      end
    end

    def keyword_candidates(doc)
      text = doc.at("body")&.text.to_s.gsub(/\s+/, " ")
      pattern = /(?:\bnav\b|net asset value|\bprice\b|القيمة|السعر)[^0-9]{0,40}([0-9]{1,6}(?:[.,][0-9]{1,7})?)/i
      text.scan(pattern).flatten.compact
    end

    def extract_numbers_from_text(text)
      text.to_s.scan(/\b([0-9]{1,6}(?:[.,][0-9]{1,7})?)\b/).flatten
    end

    def parse_number(raw)
      return nil if raw.nil?

      token = raw.to_s.strip.delete(",")
      return nil unless token.match?(/\A\d+(?:\.\d+)?\z/)

      token.to_f
    end

    def normalize_price(raw)
      return nil if raw.nil?

      token = raw.to_s.strip
      token = token.tr(",", ".")
      token = token.gsub(/[^\d.]/, "")
      return nil if token.empty?
      return nil if token.count(".") > 1

      token.to_f
    end

    def valid_price?(value, max_price:)
      value && value.positive? && value <= max_price
    end
  end
end
