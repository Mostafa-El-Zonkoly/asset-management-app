# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/mubasher/index_fetcher")

# Fixture-only tests for the index-level parser. No live network and no market
# values are hardcoded as truth — the fixtures ARE synthetic pages, and we assert
# the parser recovers the level the fixture embeds (spec #18: verify math/logic
# from fixtures, not by baking in a real market number).
class Mubasher::IndexFetcherTest < ActiveSupport::TestCase
  def fetcher = Mubasher::IndexFetcher.new

  # The real Mubasher market-summary block: the level lives in
  # `.market-summary__last-price` (arrow is a CSS ::before, so node text is just
  # the number). The change row and date carry other numbers that must NOT win.
  test "reads the level from the market-summary last-price element, ignoring noise" do
    html = <<~HTML
      <div class="market-summary__block">
        <div class="market-summary__date">Last update: Wednesday, September 16</div>
        <div class="market-summary__last-price down-icon-only">6,639.47</div>
        <div class="market-summary__change-row">
          <span>-65.71</span><span>-0.98%</span><span>6,705.18</span>
          <span>6,705.18</span><span>6,705.18</span>
        </div>
      </div>
    HTML
    assert_in_delta 6_639.47, fetcher.extract_level(html: html), 1e-6
  end

  test "reads a plain level directly after the update date" do
    html = <<~HTML
      <div class="market-summary__block">
        <time>Last update: Thursday, September 17</time>
        <strong>54,909.17</strong>
        <div>Previous Close 54,796.55</div>
      </div>
    HTML
    assert_in_delta 54_909.17, fetcher.extract_level(html: html), 1e-6
  end

  test "handles an ungrouped index level in the price element" do
    assert_in_delta 6_651.18, fetcher.extract_level(html: '<span class="market-summary__last-price">6651.18</span>'), 1e-6
  end

  test "ignores an adjacent change when the last level is missing" do
    html = <<~HTML
      <div class="market-summary__date">Last update: Thursday, September 17</div>
      <span class="market-summary__change">460.30</span>
    HTML
    assert_nil fetcher.extract_level(html: html)
  end

  test "does not guess a level from previous closes or unrelated numbers" do
    html = "<div>Previous Close 54,796.55</div><footer>54,796.55</footer>"
    assert_nil fetcher.extract_level(html: html)
  end

  test "rejects a URL without mubasher.info before any network call" do
    assert_raises(Mubasher::FetchError) { fetcher.fetch_level_from_url(url: "https://example.com/mubasher.info/egx30") }
  end
end
