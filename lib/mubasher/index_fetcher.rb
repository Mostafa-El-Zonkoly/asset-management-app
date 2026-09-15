require "faraday"
require "json"
require "nokogiri"
require "time"
require_relative "fetcher" # defines Mubasher::FetchError

module Mubasher
  # Fetches an index's daily CLOSING level from Mubasher (e.g. EGX30, EGX33
  # Shariah). Kept separate from the stock Fetcher because index levels are large,
  # thousands-grouped numbers ("54,909.17") that the stock parser (tuned for share
  # prices under ~100k, no grouping) would mis-read. This one understands grouped
  # thousands and constrains to a plausible index range.
  #
  # The extraction is heuristic (Mubasher exposes no public quote API): it collects
  # numeric candidates from JSON-LD, price-ish nodes and the raw HTML, keeps only
  # those inside [min_level, max_level], and returns the most frequently occurring
  # in-range value (a page repeats the live level in several places — header, chart,
  # summary — so the true level dominates), preferring values carrying a decimal
  # fraction. Deterministic and unit-testable via extract_level(html:).
  class IndexFetcher
    DEFAULT_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9,ar;q=0.8"
    }.freeze

    DEFAULT_MIN_LEVEL = 100.0
    DEFAULT_MAX_LEVEL = 10_000_000.0

    def initialize(min_level: DEFAULT_MIN_LEVEL, max_level: DEFAULT_MAX_LEVEL)
      @min_level = min_level
      @max_level = max_level
    end

    # Fetch the current level from a full Mubasher index URL.
    def fetch_level_from_url(url:)
      raise FetchError, "url is required" if url.to_s.strip.empty?
      raise FetchError, "url must include mubasher.info" unless url.include?("mubasher.info")

      response = Faraday.get(url) do |req|
        DEFAULT_HEADERS.each { |k, v| req.headers[k] = v }
      end
      raise FetchError, "Mubasher returned status #{response.status}" unless response.success?

      html = response.body.to_s
      level = extract_level(html: html)
      raise FetchError, "Could not extract an index level from #{url} (page structure may have changed)." if level.nil?

      { level: level, source: "mubasher_index_url", fetched_at: Time.now.utc.iso8601, url: url }
    rescue Faraday::Error => e
      raise FetchError, "Mubasher request failed: #{e.message}"
    end

    # Pure extraction from an HTML string. Exposed for fixture-based tests.
    def extract_level(html:)
      doc = safe_parse(html)
      candidates = []
      candidates.concat(json_ld_numbers(doc)) if doc
      candidates.concat(grouped_number_tokens(html))
      candidates.concat(plain_number_tokens(html))

      values = candidates.filter_map { |tok| normalize(tok) }.select { |v| in_range?(v) }
      return nil if values.empty?

      pick_level(values)
    end

    private

    def safe_parse(html)
      Nokogiri::HTML(html.to_s)
    rescue Nokogiri::XML::SyntaxError
      nil
    end

    def json_ld_numbers(doc)
      out = []
      doc.css('script[type="application/ld+json"]').each do |script|
        payload = JSON.parse(script.text) rescue next
        out.concat(numbers_recursive(payload))
      end
      out
    end

    def numbers_recursive(value)
      case value
      when Hash  then value.values.flat_map { |v| numbers_recursive(v) }
      when Array then value.flat_map { |v| numbers_recursive(v) }
      when Numeric then [value.to_s]
      when String then grouped_number_tokens(value) + plain_number_tokens(value)
      else []
      end
    end

    # "54,909.17" / "6,651.18" — thousands-grouped, optional decimal fraction.
    def grouped_number_tokens(text)
      text.to_s.scan(/\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b/)
    end

    # "6651.18" / "54909" — ungrouped numbers (fallback).
    def plain_number_tokens(text)
      text.to_s.scan(/\b\d{3,9}(?:\.\d{1,6})?\b/)
    end

    def normalize(token)
      t = token.to_s.delete(",")
      return nil if t.empty? || t.count(".") > 1

      Float(t)
    rescue ArgumentError, TypeError
      nil
    end

    def in_range?(value)
      value && value >= @min_level && value <= @max_level
    end

    # A page repeats the true level several times; pick the most frequent in-range
    # value, breaking ties toward a value that has a non-zero decimal fraction
    # (index levels are quoted to 2dp) and then toward the larger magnitude.
    def pick_level(values)
      rounded = values.map { |v| v.round(2) }
      counts = Hash.new(0)
      rounded.each { |v| counts[v] += 1 }

      counts.max_by do |value, count|
        has_fraction = (value - value.floor).abs > 1e-9 ? 1 : 0
        [count, has_fraction, value]
      end&.first
    end
  end
end
