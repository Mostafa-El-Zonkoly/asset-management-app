# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/efg/client")

# Canned-response tests for the EFG client. No live network.
class Efg::ClientTest < ActiveSupport::TestCase
  Response = Struct.new(:status, :body)

  class StubClient < Efg::Client
    attr_reader :calls

    def initialize(responses, **kw)
      super(trading_id: "TID", api_key: "SECRET-KEY", **kw)
      @responses = responses
      @calls = []
    end

    private

    def http_request(method, url, headers, body)
      path = url.delete_prefix(BASE_URL)
      @calls << { method: method, path: path, headers: headers, body: body }
      handler = @responses.fetch(path) { raise "unexpected request #{path}" }
      handler = handler.shift if handler.is_a?(Array)
      handler.is_a?(Proc) ? handler.call : handler
    end
  end

  def ok(payload) = Response.new(200, JSON.generate(payload))

  AUTH = { "data" => { "accessToken" => "tok123", "expiresIn" => 3600 } }.freeze
  STOCKS = { "data" => [
    { "stockId" => 11, "symbol" => "ABUK" },
    { "id" => 22, "reuterCode" => "AMOC.CA" },
    { "stockId" => 33, "symbol" => "DUP" },
    { "stockId" => 34, "symbol" => "DUP" }
  ] }.freeze

  setup { Efg::Client.clear_cache! }
  teardown { Efg::Client.clear_cache! }

  def responses
    {
      "/api/public-keys/token" => ok(AUTH),
      "/api/stocks/market/1" => ok(STOCKS),
      "/api/stocks/stock-trading-info/1/11" => ok("data" => { "price" => 78.41 }),
      "/api/stocks/stock-trading-info/1/22" => ok("data" => { "price" => "13.47" })
    }
  end

  test "authenticates, resolves the symbol and returns the last price" do
    c = StubClient.new(responses)
    assert_in_delta 78.41, c.price("abuk")[:price], 1e-9
    assert_in_delta 13.47, c.price("AMOC")[:price], 1e-9 # resolved from reuterCode

    auth = c.calls.find { |x| x[:path] == "/api/public-keys/token" }
    assert_equal :post, auth[:method]
    assert_equal({ "tradingId" => "TID", "secret" => "SECRET-KEY" }, JSON.parse(auth[:body]))
    quote = c.calls.last
    assert_equal "Bearer tok123", quote[:headers]["Authorization"]
    assert_equal "003", quote[:headers]["x-company-code"]
    assert_equal "real", quote[:headers]["X-Server-Select"]
  end

  test "token and directory are cached across symbols" do
    c = StubClient.new(responses)
    c.price("ABUK")
    c.price("AMOC")
    assert_equal 1, c.calls.count { |x| x[:path] == "/api/public-keys/token" }
    assert_equal 1, c.calls.count { |x| x[:path] == "/api/stocks/market/1" }
  end

  test "ambiguous or unknown symbols raise" do
    c = StubClient.new(responses)
    assert_raises(Efg::FetchError) { c.price("DUP") }
    assert_raises(Efg::FetchError) { c.price("NOPE") }
  end

  test "zero or missing price raises instead of saving it" do
    r = responses.merge("/api/stocks/stock-trading-info/1/11" => ok("data" => { "price" => 0 }))
    assert_raises(Efg::FetchError) { StubClient.new(r).price("ABUK") }
  end

  test "a 401 drops the token and retries once" do
    r = responses.merge(
      "/api/public-keys/token" => [ok(AUTH), ok("data" => { "accessToken" => "tok456", "expiresIn" => 3600 })],
      "/api/stocks/stock-trading-info/1/11" => [Response.new(401, "{}"), ok("data" => { "price" => 78.41 })]
    )
    c = StubClient.new(r)
    assert_in_delta 78.41, c.price("ABUK")[:price], 1e-9
    assert_equal "Bearer tok456", c.calls.last[:headers]["Authorization"]
  end

  test "failed authentication never leaks the secret in the error" do
    r = responses.merge("/api/public-keys/token" => Response.new(403, '{"error":"SECRET-KEY bad"}'))
    err = assert_raises(Efg::FetchError) { StubClient.new(r).authenticate! }
    refute_includes err.message, "SECRET-KEY"
  end

  test "only the allowlisted read endpoints can be requested" do
    c = StubClient.new(responses)
    assert_raises(Efg::FetchError) { c.send(:request, :get, "/api/v1/orders/normal") }
    assert_raises(Efg::FetchError) { c.send(:request, :post, "/api/stocks/market/1") }
  end

  test "rejects missing credentials and unknown company codes" do
    assert_raises(Efg::FetchError) { Efg::Client.new(trading_id: "", api_key: "x") }
    assert_raises(Efg::FetchError) { Efg::Client.new(trading_id: "a", api_key: "b", company_code: "999") }
  end
end
