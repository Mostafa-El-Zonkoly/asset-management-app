require "faraday"
require "nokogiri"
require "time"
require "uri"
require_relative "fetcher" # defines Mubasher::FetchError

module Mubasher
  # Reads the published index level from Mubasher's index summary.
  class IndexFetcher
    DEFAULT_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9,ar;q=0.8"
    }.freeze

    PRICE_SELECTOR = ".market-summary__last-price"
    SUMMARY_DATE_SELECTOR = ".market-summary__date"

    DEFAULT_MIN_LEVEL = 100.0
    DEFAULT_MAX_LEVEL = 10_000_000.0

    def initialize(min_level: DEFAULT_MIN_LEVEL, max_level: DEFAULT_MAX_LEVEL)
      @min_level = min_level
      @max_level = max_level
    end

    # Fetch the current level from a full Mubasher index URL.
    def fetch_level_from_url(url:)
      raise FetchError, "url is required" if url.to_s.strip.empty?
      uri = URI.parse(url.to_s)
      unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && (uri.host == "mubasher.info" || uri.host&.end_with?(".mubasher.info"))
        raise FetchError, "A Mubasher HTTPS URL is required"
      end

      response = Faraday.get(url) do |req|
        req.options.open_timeout = 5
        req.options.timeout = 10
        DEFAULT_HEADERS.each { |k, v| req.headers[k] = v }
      end
      raise FetchError, "Mubasher returned status #{response.status}" unless response.success?

      html = response.body.to_s
      level = extract_level(html: html)
      raise FetchError, "Could not extract an index level from #{url} (page structure may have changed)." if level.nil?

      { level: level, source: "mubasher_index_url", fetched_at: Time.now.utc.iso8601, url: url }
    rescue URI::InvalidURIError
      raise FetchError, "Invalid Mubasher index URL"
    rescue Faraday::Error => e
      raise FetchError, "Mubasher request failed: #{e.message}"
    end

    def extract_level(html:)
      doc = Nokogiri::HTML(html.to_s)

      doc.css(PRICE_SELECTOR).each do |node|
        level = normalize_level(node.text)
        return level if level
      end

      # The summary places the level directly after the last-update date.
      dates = doc.css(SUMMARY_DATE_SELECTOR)
      dates |= doc.css(".market-summary, .market-summary__block").xpath(
        ".//*[not(*) and (starts-with(normalize-space(.), 'Last update:') or starts-with(normalize-space(.), 'آخر تحديث:'))]"
      )
      dates.each do |date|
        value = date.next_element
        next unless value && !value["class"].to_s.match?(/change|open|close|volume|turnover/i)

        level = normalize_level(value.text)
        return level if level
      end

      nil
    end

    private

    def normalize_level(text)
      number = text.to_s.strip
      return unless number.match?(/\A(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?\z/)

      value = Float(number.delete(","))
      value if value.between?(@min_level, @max_level)
    end
  end
end
