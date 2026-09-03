# frozen_string_literal: true

require "set"

# Ranks Core-candidate direct stocks by a configurable Core Add Score (/100).
#
# Manual factors (entry / quality / catalyst, each 0-10) come from the asset.
# Weight-balance factors (stock / sector / subsector) are computed from holdings
# in the chosen scope and reward UNDER-represented positions. Sharia comes from
# zaka_percentage (or a manual override). A technical helper (distance off the
# 52-week high and vs a moving average) is attached for display only and does
# NOT affect the score — the user excludes technically-extended names manually.
module CoreAddScoreService
  Row = Struct.new(
    :asset, :held, :total, :factors, :weights_pct, :technical,
    keyword_init: true
  )

  module_function

  # portfolio_ids: scope for the weight-balance factors (nil => all portfolios).
  def rank(portfolio_ids: nil, include_watchlist: true)
    cfg = CoreScoringSetting.record
    ids = PortfolioStatsService.normalize_ids(portfolio_ids)
    w = weight_maps(ids)

    assets = Asset.active.direct_stock.core_candidates
                  .includes(:sector, :speciality, :currency).to_a
    assets = assets.select { |a| w[:held_ids].include?(a.id) } unless include_watchlist

    assets.map { |a| score_row(a, cfg, w) }
          .sort_by { |r| [-r.total, -(r.factors[:entry] || 0)] }
  end

  def score_row(asset, cfg, w)
    total_book = w[:total]
    stock_pct  = pct(w[:asset][asset.id], total_book)
    sector_pct = pct(w[:sector][asset.sector_id], total_book)
    spec_pct   = pct(w[:spec][[asset.sector_id, asset.speciality_id]], total_book)

    factors = {
      entry:     frac10(asset.entry_score)    * cfg.weight_entry.to_d,
      quality:   frac10(asset.quality_score)  * cfg.weight_quality.to_d,
      catalyst:  frac10(asset.catalyst_score) * cfg.weight_catalyst.to_d,
      stock:     band(stock_pct,  cfg.stock_full_pct,     cfg.stock_cap_pct)     * cfg.weight_stock.to_d,
      sector:    band(sector_pct, cfg.sector_full_pct,    cfg.sector_cap_pct)    * cfg.weight_sector.to_d,
      subsector: band(spec_pct,   cfg.subsector_full_pct, cfg.subsector_cap_pct) * cfg.weight_subsector.to_d,
      sharia:    sharia_frac(asset, cfg) * cfg.weight_sharia.to_d
    }
    max = cfg.total_weight
    total100 = max.nonzero? ? (factors.values.sum / max * 100) : 0.to_d

    Row.new(
      asset: asset,
      held: w[:held_ids].include?(asset.id),
      total: total100,
      factors: factors,
      weights_pct: { stock: stock_pct, sector: sector_pct, subsector: spec_pct },
      technical: technical_for(asset, cfg)
    )
  end

  # 0-10 manual score -> 0..1 fraction (nil/blank => 0).
  def frac10(score)
    return 0.to_d if score.blank?

    [[score.to_d / 10, 0.to_d].max, 1.to_d].min
  end

  # 1.0 at/below full, 0.0 at/above cap, linear between. Lower weight => higher score.
  def band(value_pct, full, cap)
    full = full.to_d
    cap = cap.to_d
    value_pct = value_pct.to_d
    return 1.to_d if value_pct <= full
    return 0.to_d if value_pct >= cap || cap <= full

    (cap - value_pct) / (cap - full)
  end

  def sharia_frac(asset, cfg)
    return frac10(asset.sharia_score_override) if asset.sharia_score_override.present?

    clean = cfg.sharia_clean_pct.to_d
    dirty = cfg.sharia_dirty_pct.to_d
    z = asset.zaka_percentage.to_d
    return 1.to_d if z <= clean
    return 0.to_d if z >= dirty || dirty <= clean

    (dirty - z) / (dirty - clean)
  end

  def pct(value, total)
    total.to_d.nonzero? ? (value.to_d / total.to_d * 100) : 0.to_d
  end

  # Scope-aware direct-stock value maps (the "stocks part" denominators).
  def weight_maps(ids)
    asset_v = Hash.new(0.to_d)
    sector_v = Hash.new(0.to_d)
    spec_v = Hash.new(0.to_d)
    held = Set.new

    scope = Holding.joins(:asset).merge(Asset.active).includes(asset: [ :asset_type, :sector, :speciality ])
    scope = scope.where(portfolio_id: ids) if ids
    scope.find_each do |h|
      next unless h.asset.direct_stock? && h.asset.sector_id.present?

      v = HoldingsCalculatorService.for_holding(h).current_value
      held << h.asset_id if h.quantity.to_d.positive?
      asset_v[h.asset_id] += v
      sector_v[h.asset.sector_id] += v
      spec_v[[h.asset.sector_id, h.asset.speciality_id]] += v
    end

    { asset: asset_v, sector: sector_v, spec: spec_v, total: asset_v.values.sum, held_ids: held }
  end

  # Technical context (display only): latest price, 52-week high, N-day MA,
  # distance off the high, distance above the MA, and an "extended" flag.
  def technical_for(asset, cfg)
    rows = asset.asset_prices.where(currency_id: asset.currency_id)
                .order(date: :desc).limit(400).pluck(:date, :price)
    blank = { last: nil, high_52w: nil, ma: nil, off_high_pct: nil, above_ma_pct: nil, extended: false }
    return blank if rows.empty?

    last = rows.first[1].to_d
    cutoff = rows.first[0] - 365
    year_prices = rows.select { |d, _| d >= cutoff }.map { |_, pr| pr.to_d }
    high_52w = year_prices.max

    ma_window = rows.first(cfg.ma_period_days).map { |_, pr| pr.to_d }
    ma = ma_window.empty? ? nil : (ma_window.sum / ma_window.size)

    off_high = high_52w && high_52w.nonzero? ? ((high_52w - last) / high_52w * 100) : nil
    above_ma = ma && ma.nonzero? ? ((last - ma) / ma * 100) : nil
    extended = (off_high && off_high <= cfg.extended_near_high_pct.to_d) ||
               (above_ma && above_ma >= cfg.extended_above_ma_pct.to_d)

    { last: last, high_52w: high_52w, ma: ma, off_high_pct: off_high, above_ma_pct: above_ma, extended: !!extended }
  end
end
