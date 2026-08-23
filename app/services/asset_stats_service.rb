# frozen_string_literal: true

class AssetStatsService
  class << self
    # portfolio: when set, stats are limited to that portfolio’s holding(s) for this asset.
    # When nil (default for asset page), all holdings across portfolios are aggregated.
    def summary(asset, portfolio: nil)
      new(asset, portfolio: portfolio).summary
    end

    def price_series(asset, range_key: "3m")
      new(asset).price_series(range_key)
    end

    def index_series(asset, range_key: "3m")
      new(asset).index_series(range_key)
    end

    # Percent change from earliest to latest quote in +points+ (chronological order), matching the chart summary.
    def interval_change_percent_for_series(points)
      return nil if points.blank? || points.size < 2

      nums = points.map { |pt| pt[:price].to_f }
      first = nums.first
      last = nums.last
      return nil if first.zero? || nums.any? { |n| n.nan? }

      ((last / first) - 1) * 100
    end
  end

  def initialize(asset, portfolio: nil)
    @asset = asset
    @portfolio = portfolio
  end

  def summary
    holdings = holdings_for_asset
    holdings = holdings.reject { |h| h.asset.wallet? }
    return default_summary if holdings.empty?

    calcs = holdings.map { |h| HoldingsCalculatorService.for_holding(h) }

    {
      current_price: latest_price&.to_f,
      average_buy_price: weighted_average_buy_price(holdings)&.to_f,
      quantity: holdings.sum { |h| h.quantity.to_d }.to_f,
      current_value: calcs.sum(&:current_value).to_f,
      unrealised_gain: calcs.sum(&:unrealised_gain).to_f,
      realised_gain: calcs.sum(&:realised_gain).to_f,
      total_dividends: calcs.sum(&:total_dividends).to_f
    }
  end

  def price_series(range_key)
    range = ChartRangeHelper.range(range_key)
    scope = @asset.asset_prices.where(currency_id: @asset.currency_id).order(:date)
    scope = scope.where(date: range) if range
    scope.pluck(:date, :price).map { |d, p| { date: d.iso8601, price: p.to_f } }
  end

  def index_series(range_key)
    return [] unless @asset.market_index_id

    range = ChartRangeHelper.range(range_key)
    scope = @asset.market_index.index_prices.order(:date)
    scope = scope.where(date: range) if range
    scope.pluck(:date, :price).map { |d, p| { date: d.iso8601, price: p.to_f } }
  end

  private

  def holdings_for_asset
    rel = @portfolio ? @portfolio.holdings.where(asset: @asset) : @asset.holdings
    rel.includes(:portfolio, :asset).to_a
  end

  def weighted_average_buy_price(holdings)
    num = 0.to_d
    den = 0.to_d
    holdings.each do |h|
      q = h.quantity.to_d
      a = h.average_buy_price&.to_d
      next if a.nil? || q.zero?

      num += q * a
      den += q
    end
    den.zero? ? nil : (num / den)
  end

  def latest_price
    @asset.asset_prices.where(currency_id: @asset.currency_id).order(date: :desc).first&.price
  end

  def default_summary
    {
      current_price: latest_price&.to_f,
      average_buy_price: nil,
      quantity: nil,
      current_value: nil,
      unrealised_gain: nil,
      realised_gain: nil,
      total_dividends: nil
    }
  end
end
