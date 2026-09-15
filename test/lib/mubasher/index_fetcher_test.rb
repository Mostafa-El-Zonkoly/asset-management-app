# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/mubasher/index_fetcher")

# Fixture-only tests for the index-level parser. No live network and no market
# values are hardcoded as truth — the fixtures ARE synthetic pages, and we assert
# the parser recovers the level the fixture embeds (spec #18: verify math/logic
# from fixtures, not by baking in a real market number).
class Mubasher::IndexFetcherTest < ActiveSupport::TestCase
  def fetcher = Mubasher::IndexFetcher.new

  # EGX-style page: thousands-grouped level repeated across header/summary/script.
  test "extracts a thousands-grouped index level (54,909.17)" do
    html = <<~HTML
      <h1>EGX 30</h1>
      <span class="value">54,909.17</span>
      <div class="change">+112.62 (+0.21%)</div>
      <script type="application/ld+json">{"name":"EGX 30","last":54909.17,"prevClose":54796.55}</script>
      <div class="prev">Prev close 54,796.55</div>
      <footer>Volume 1,234,567 shares</footer>
    HTML
    assert_in_delta 54_909.17, fetcher.extract_level(html: html), 1e-6
  end

  test "extracts a smaller grouped level (6,651.18) for a Shariah-style page" do
    html = <<~HTML
      <h1>EGX 33 Shariah</h1>
      <span>6,651.18</span>
      <div>+65.71 (+1.00%)</div>
      <span class="repeat">6,651.18</span>
      <div>Prev 6,585.47</div>
    HTML
    assert_in_delta 6_651.18, fetcher.extract_level(html: html), 1e-6
  end

  test "handles an ungrouped decimal level" do
    html = "<div class='idx'>6651.18</div><div class='idx'>6651.18</div><p>chg 0.5</p>"
    assert_in_delta 6_651.18, fetcher.extract_level(html: html), 1e-6
  end

  test "returns nil when no in-range level is present" do
    assert_nil fetcher.extract_level(html: "<p>share price 12.34, qty 5</p>")
  end

  test "picks the repeated true level over a one-off out-of-place number" do
    html = <<~HTML
      <span>54,909.17</span><span>54,909.17</span><span>54,909.17</span>
      <aside>lucky number 99,999.99</aside>
    HTML
    assert_in_delta 54_909.17, fetcher.extract_level(html: html), 1e-6
  end

  test "rejects a URL without mubasher.info before any network call" do
    assert_raises(Mubasher::FetchError) { fetcher.fetch_level_from_url(url: "https://example.com/egx30") }
  end
end
