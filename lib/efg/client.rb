# frozen_string_literal: true

require "faraday"
require "json"
require "digest"
require_relative "fetch_error"

module Efg
  # Read-only client for the EFG Hermes ONE trading API (the same REST endpoints
  # the official younit SDK uses). Only the three endpoints below are allowed;
  # there is deliberately no way to reach order/account endpoints from here.
  #
  #   client = Efg::Client.new(trading_id: "...", api_key: "...", company_code: "003")
  #   client.price("ABUK") # => { price: 78.41, stock_id: 123, symbol: "ABUK", ... }
  #
  # Error messages never include credentials, tokens or raw response bodies.
  class Client
    class UnauthorizedError < FetchError; end

    BASE_URL = "https://tradingapis.efghermesone.com"
    AUTH_PATH = "/api/public-keys/token"
    MARKET_ID = 1 # EGX

    ALLOWED_PATHS = [
      %r{\A/api/public-keys/token\z},
      %r{\A/api/stocks/market/\d+\z},
      %r{\A/api/stocks/stock-trading-info/\d+/\d+\z}
    ].freeze

    COMPANY_CODES = %w[003 009].freeze
    STOCKS_TTL = 6 * 3600 # symbol => stockId directory changes rarely
    TOKEN_SAFETY_MARGIN = 300
    MAX_PRICE = 1_000_000.0

    # Process-wide caches, keyed by a digest of the credentials so a changed key
    # never reuses a token obtained with the old one.
    @cache = {}
    @mutex = Mutex.new
    class << self
      attr_reader :cache, :mutex

      def clear_cache!
        mutex.synchronize { cache.clear }
      end
    end

    def initialize(trading_id:, api_key:, company_code: "003")
      @trading_id = trading_id.to_s.strip
      @api_key = api_key.to_s.strip
      @company_code = company_code.to_s.strip.presence || "003"
      raise FetchError, "EFG credentials are not configured" if @trading_id.empty? || @api_key.empty?
      raise FetchError, "EFG company code must be 003 or 009" unless COMPANY_CODES.include?(@company_code)

      @cache_key = Digest::SHA256.hexdigest([@trading_id, @api_key, @company_code].join("\0"))
    end

    # Authenticate (or reuse a valid token). Returns true; raises FetchError.
    def authenticate!
      token
      true
    end

    def price(symbol)
      symbol = symbol.to_s.upcase.strip
      raise FetchError, "symbol is required" if symbol.empty?

      stock_id = stock_id_for(symbol)
      payload = unwrap(get("/api/stocks/stock-trading-info/#{MARKET_ID}/#{stock_id}"))
      raise FetchError, "Unexpected EFG quote response for #{symbol}" unless payload.is_a?(Hash)

      price = Float(payload["price"], exception: false)
      unless price&.finite? && price.positive? && price <= MAX_PRICE
        raise FetchError, "EFG returned no valid price for #{symbol}"
      end

      { price: price, stock_id: stock_id, symbol: symbol, source: "efg_api" }
    end

    private

    def stock_id_for(symbol)
      stocks = cached(:stocks, STOCKS_TTL) { load_stocks }
      id = stocks[symbol]
      raise FetchError, "#{symbol} not found (or not unique) in the EFG EGX directory" if id.nil?

      id
    end

    def load_stocks
      rows = unwrap(get("/api/stocks/market/#{MARKET_ID}"))
      raise FetchError, "Unexpected EFG stock directory response" unless rows.is_a?(Array) && rows.any?

      counts = Hash.new(0)
      ids = {}
      rows.each do |r|
        next unless r.is_a?(Hash)

        sym = (r["symbol"].presence || r["reuterCode"].to_s.split(".").first).to_s.upcase.strip
        id = Integer(r["stockId"] || r["id"], exception: false)
        next if sym.empty? || id.nil? || id <= 0

        counts[sym] += 1
        ids[sym] = id
      end
      ids.reject { |sym, _| counts[sym] > 1 } # ambiguous symbols are refused
    end

    def token
      cached(:token, nil) { request_token }
    end

    def request_token
      body = unwrap(request(:post, AUTH_PATH, body: { tradingId: @trading_id, secret: @api_key }, auth: false))
      access = body.is_a?(Hash) ? body["accessToken"] : nil
      expires_in = body.is_a?(Hash) ? Integer(body["expiresIn"], exception: false) : nil
      raise FetchError, "Unexpected EFG authentication response" if access.blank? || expires_in.nil? || expires_in <= 0

      ttl = [expires_in - TOKEN_SAFETY_MARGIN, 60].max
      [ "Bearer #{access}", ttl ]
    end

    # Cache helper. The block returns a value, or [value, ttl] when ttl is nil.
    def cached(name, ttl)
      key = [@cache_key, name]
      Client.mutex.synchronize do
        entry = Client.cache[key]
        return entry[:value] if entry && monotonic_now < entry[:expires_at]
      end

      result = yield
      if ttl.nil?
        value, ttl = result
      else
        value = result
      end
      Client.mutex.synchronize do
        Client.cache[key] = { value: value, expires_at: monotonic_now + ttl }
      end
      value
    end

    def get(path)
      request(:get, path)
    rescue UnauthorizedError
      # Token revoked/expired early: drop it and retry exactly once.
      Client.mutex.synchronize { Client.cache.delete([@cache_key, :token]) }
      request(:get, path)
    end

    def request(method, path, body: nil, auth: true)
      raise FetchError, "EFG endpoint not allowed" unless ALLOWED_PATHS.any? { |re| re.match?(path) }
      raise FetchError, "Only authentication may POST" if method != :get && path != AUTH_PATH

      headers = {
        "Accept" => "application/json",
        "Content-Type" => "application/json",
        "Accept-Language" => "en",
        "X-Server-Select" => "real",
        "x-company-code" => @company_code,
        "x-api-version" => "1.0"
      }
      headers["Authorization"] = token if auth

      response = http_request(method, BASE_URL + path, headers, body && JSON.generate(body))
      status = response.status.to_i
      raise UnauthorizedError, "EFG rejected the credentials (HTTP 401)" if status == 401 && auth
      raise FetchError, "EFG authentication failed (HTTP #{status}); check Trading ID / API key" if !auth && !(200..299).cover?(status)
      raise FetchError, "EFG returned HTTP #{status}" unless (200..299).cover?(status)

      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise FetchError, "EFG returned invalid JSON"
    rescue Faraday::Error
      raise FetchError, "Could not connect to EFG"
    end

    # Isolated for tests.
    def http_request(method, url, headers, body)
      Faraday.run_request(method, url, body, headers) do |req|
        req.options.timeout = 20
        req.options.open_timeout = 10
      end
    end

    def unwrap(payload)
      2.times { payload = payload["data"] if payload.is_a?(Hash) && payload.key?("data") }
      payload
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
