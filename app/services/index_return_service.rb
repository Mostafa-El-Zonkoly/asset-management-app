# frozen_string_literal: true

require "bigdecimal"

# Simple price return of a market index between two dates, from stored index_prices
# (carry-forward to the nearest prior trading day). An index has no external cash
# flows, so its price return IS its time-weighted return — directly comparable to a
# portfolio's TWR for computing alpha (portfolio_return - benchmark_return).
class IndexReturnService
  class << self
    # Percent return over (from, to]; nil when either endpoint has no prior price.
    def percent(market_index, from:, to:)
      return nil if market_index.nil?

      series = IndexPrice.where(market_index_id: market_index.id).order(:date).pluck(:date, :price)
      return nil if series.blank?

      p0 = price_asof(series, from)
      p1 = price_asof(series, to)
      return nil if p0.nil? || p1.nil? || p0.zero?

      ((p1 / p0) - 1) * 100
    end

    private

    def price_asof(series, d)
      ans = nil
      series.each do |date, price|
        break if date > d

        ans = price
      end
      ans&.to_d
    end
  end
end
