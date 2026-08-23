require "faraday"
require "json"
require "nokogiri"
require "time"

module Mubasher
  class FetchError < StandardError; end

  class Fetcher
    DEFAULT_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9,ar;q=0.8"
    }.freeze

    DEFAULT_MAX_PRICE = 100_000.0

    # Fetch by EGX symbol, e.g. "ABUK"
    def fetch_stock_price(symbol:, market: "EGX", max_price: DEFAULT_MAX_PRICE)
      raise FetchError, "symbol is required" if symbol.to_s.strip.empty?

      url = "https://www.mubasher.info/markets/#{market}/stocks/#{symbol.to_s.upcase.strip}"
      result = fetch_price_from_url(url: url, max_price: max_price)
      result.merge(source: "mubasher_symbol", symbol: symbol.to_s.upcase.strip, market: market)
    end

    # Fetch from full Mubasher URL (stock/fund/custom page)
    def fetch_price_from_url(url:, max_price: DEFAULT_MAX_PRICE)
      raise FetchError, "url is required" if url.to_s.strip.empty?
      raise FetchError, "url must include mubasher.info" unless url.include?("mubasher.info")

      response = Faraday.get(url) do |req|
        DEFAULT_HEADERS.each { |k, v| req.headers[k] = v }
      end

      raise FetchError, "Mubasher returned status #{response.status}" unless response.success?

      html = response.body.to_s
      doc = Nokogiri::HTML(html)
      price = extract_price(doc: doc, html: html, max_price: max_price)

      {
        price: price,
        source: "mubasher_url",
        fetched_at: Time.now.utc.iso8601,
        url: url
      }
    rescue Nokogiri::XML::SyntaxError => e
      raise FetchError, "Failed to parse Mubasher HTML: #{e.message}"
    end

    private

    def extract_price(doc:, html:, max_price:)
      candidates = []
      candidates.concat(json_ld_candidates(doc))
      candidates.concat(css_candidates(doc))
      candidates.concat(h1_neighborhood_candidates(doc))
      candidates.concat(raw_html_candidates(html))
      candidates.concat(generic_decimal_candidates(html))

      candidates.each do |candidate|
        numeric = normalize_price(candidate)
        return numeric if valid_price?(numeric, max_price: max_price)
      end

      raise FetchError, "Could not extract a valid price from Mubasher page. Structure may have changed."
    end

    def json_ld_candidates(doc)
      values = []
      doc.css('script[type="application/ld+json"]').each do |script|
        begin
          payload = JSON.parse(script.text)
        rescue JSON::ParserError
          next
        end

        values.concat(find_numbers_recursive(payload))
      end
      values
    end

    def find_numbers_recursive(value)
      case value
      when Hash
        value.values.flat_map { |v| find_numbers_recursive(v) }
      when Array
        value.flat_map { |v| find_numbers_recursive(v) }
      when Numeric
        [value.to_s]
      when String
        extract_numbers_from_text(value)
      else
        []
      end
    end

    def css_candidates(doc)
      selectors = [
        '[class*="price"]',
        '[class*="nav"]',
        '[class*="value"]',
        '[id*="price"]',
        '[id*="nav"]',
        ".stock-price",
        ".current-price",
        ".nav-value"
      ]

      selectors.flat_map do |selector|
        doc.css(selector).flat_map { |node| extract_numbers_from_text(node.text.to_s) }
      end
    end

    def h1_neighborhood_candidates(doc)
      h1 = doc.css("h1").first
      return [] unless h1

      scope_text = [h1.text, h1.parent&.text, h1.next_element&.text].compact.join(" ")
      extract_numbers_from_text(scope_text)
    end

    def raw_html_candidates(html)
      patterns = [
        /(?:nav|net asset value|price|القيمة|السعر|آخر تحديث)[^0-9]{0,40}([0-9]{1,6}(?:[.,][0-9]{1,7})?)/i,
        /([0-9]{1,6}(?:[.,][0-9]{1,7})?)\s*(?:egp|usd|sar|aed|جنيه|دولار)?/i
      ]

      patterns.flat_map { |pattern| html.scan(pattern).flatten.compact }
    end

    def generic_decimal_candidates(html)
      html.scan(/\b([0-9]{1,6}(?:\.[0-9]{1,7})?)\b/).flatten
    end

    def extract_numbers_from_text(text)
      text.to_s.scan(/\b([0-9]{1,6}(?:[.,][0-9]{1,7})?)\b/).flatten
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
