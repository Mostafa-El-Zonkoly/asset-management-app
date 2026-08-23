# frozen_string_literal: true

# Per held direct stock: latest stored price inside [range_begin, range_end] (inclusive)
# vs the latest stored price strictly before range_begin (same currency as the asset).
# Only includes active direct stocks with positive net quantity across holdings.
class AssetDayPerformanceService
  Row = Struct.new(:asset, :day_price, :prior_price, :change, :change_pct, keyword_init: true)

  class << self
    def call(range_begin:, range_end:)
      range_begin, range_end = normalize_range(range_begin, range_end)

      held_ids = held_direct_stock_asset_ids
      return [] if held_ids.empty?

      assets = Asset.active.direct_stock.where(id: held_ids).includes(:currency).order(:code).to_a
      return [] if assets.empty?

      asset_ids = assets.map(&:id)
      in_range_by_id = latest_in_range_index(asset_ids, range_begin, range_end)
      prior_by_id = prior_prices_index(asset_ids, range_begin)

      assets.map do |asset|
        in_range_p = in_range_by_id[asset.id]
        prior_p = prior_by_id[asset.id]
        change = nil
        change_pct = nil
        if in_range_p && prior_p
          change = in_range_p.price.to_d - prior_p.price.to_d
          denom = prior_p.price.to_d
          change_pct = denom.nonzero? ? (change / denom) * 100 : nil
        end

        Row.new(asset: asset, day_price: in_range_p, prior_price: prior_p, change: change, change_pct: change_pct)
      end
    end

    private

    def normalize_range(range_begin, range_end)
      b = range_begin
      e = range_end
      return [ b, e ] if b <= e

      [ e, b ]
    end

    def held_direct_stock_asset_ids
      Holding
        .joins(:asset)
        .merge(Asset.active.direct_stock)
        .group(:asset_id)
        .having("SUM(holdings.quantity) > 0")
        .pluck(:asset_id)
    end

    def latest_in_range_index(asset_ids, range_begin, range_end)
      return {} if asset_ids.empty?

      placeholders = asset_ids.map { "?" }.join(",")
      sql = <<~SQL.squish
        SELECT DISTINCT ON (ap.asset_id) ap.*
        FROM asset_prices ap
        INNER JOIN assets a ON a.id = ap.asset_id AND ap.currency_id = a.currency_id
        WHERE ap.asset_id IN (#{placeholders})
          AND ap.date >= ?
          AND ap.date <= ?
        ORDER BY ap.asset_id, ap.date DESC
      SQL
      rows = AssetPrice.find_by_sql([ sql, *asset_ids, range_begin, range_end ])
      rows.index_by(&:asset_id)
    end

    def prior_prices_index(asset_ids, date)
      return {} if asset_ids.empty?

      placeholders = asset_ids.map { "?" }.join(",")
      sql = <<~SQL.squish
        SELECT DISTINCT ON (ap.asset_id) ap.*
        FROM asset_prices ap
        INNER JOIN assets a ON a.id = ap.asset_id AND ap.currency_id = a.currency_id
        WHERE ap.asset_id IN (#{placeholders})
          AND ap.date < ?
        ORDER BY ap.asset_id, ap.date DESC
      SQL
      rows = AssetPrice.find_by_sql([ sql, *asset_ids, date ])
      rows.index_by(&:asset_id)
    end
  end
end
