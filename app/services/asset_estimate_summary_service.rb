# frozen_string_literal: true

# Aggregates an asset's AssetEstimates into per-section, per-horizon summaries.
#
# Rules (see feature spec):
#   * Never mix estimate_types or horizons in one average.
#   * Data-only rows (data_role == "data") never contribute a target.
#   * Aggregates use ONE representative per source_family (independent set), so a
#     consensus republished on two sites counts once. Representative preference:
#     manually preferred, then most recent, then highest confidence.
#   * Median is the headline; min = conservative, max = optimistic.
#   * Weighted average uses confidence_score (equal weights when absent).
#   * Upside % = (target / current_price - 1) * 100, current = latest stored price.
#   * Stale rows may be excluded from current aggregates (exclude_stale:), but the
#     raw rows remain available for display/history.
#
# All target math is done in the ASSET's own currency (targets converted per row),
# so min/median/max/upside are comparable.
class AssetEstimateSummaryService
  Aggregate = Struct.new(
    :section, :estimate_type, :horizon_type,
    :raw_count, :independent_count, :not_independent,
    :min, :median, :max, :simple_avg, :weighted_avg, :nearest,
    :min_upside, :median_upside, :max_upside, :weighted_upside, :nearest_upside,
    :currency_code, :representatives, :all_rows,
    keyword_init: true
  )

  Result = Struct.new(
    :asset, :current_price, :currency_code,
    :sections,          # { fundamental: [Aggregate...], consensus: [...], technical: [...] }
    :as_of, :exclude_stale,
    keyword_init: true
  )

  class << self
    def call(asset, as_of: Date.current, exclude_stale: true)
      new(asset, as_of: as_of, exclude_stale: exclude_stale).call
    end
  end

  def initialize(asset, as_of:, exclude_stale:)
    @asset = asset
    @as_of = as_of
    @exclude_stale = exclude_stale
    @current_price = latest_price
  end

  def call
    rows = @asset.asset_estimates.active.recommending.to_a
    rows = rows.reject { |r| r.stale?(@as_of) } if @exclude_stale
    rows = rows.select { |r| r.target_price.present? }

    sections = { fundamental: [], consensus: [], technical: [] }

    rows.group_by { |r| [r.section, r.horizon_type] }.each do |(section, horizon), group|
      agg = build_aggregate(section, horizon, group)
      sections[section] << agg if sections.key?(section)
    end

    sections.each_value { |aggs| aggs.sort_by! { |a| horizon_order(a.horizon_type) } }

    Result.new(
      asset: @asset,
      current_price: @current_price,
      currency_code: @asset.currency&.code,
      sections: sections,
      as_of: @as_of,
      exclude_stale: @exclude_stale
    )
  end

  private

  def build_aggregate(section, horizon, group)
    estimate_type = group.first.estimate_type

    # One representative per source_family (the independent set).
    representatives =
      group.group_by(&:family_key).map { |_fam, fam_rows| representative_of(fam_rows) }

    targets = representatives.map { |r| target_in_asset_ccy(r) }.compact.sort

    weighted = weighted_average(representatives)
    med = median(targets)
    lo = targets.first
    hi = targets.last
    simple = targets.any? ? (targets.sum / targets.size) : nil
    nearest = nearest_to_current(targets)

    Aggregate.new(
      section: section,
      estimate_type: estimate_type,
      horizon_type: horizon,
      raw_count: group.size,
      independent_count: representatives.size,
      not_independent: group.size > representatives.size,
      min: lo, median: med, max: hi, simple_avg: simple, weighted_avg: weighted, nearest: nearest,
      min_upside: upside(lo), median_upside: upside(med), max_upside: upside(hi),
      weighted_upside: upside(weighted), nearest_upside: upside(nearest),
      currency_code: @asset.currency&.code,
      representatives: representatives.sort_by { |r| target_in_asset_ccy(r) || 0 },
      all_rows: group.sort_by { |r| [r.estimate_date, r.created_at] }.reverse
    )
  end

  # Preference: manually preferred, then most recent estimate_date, then highest
  # confidence, then newest created_at.
  def representative_of(fam_rows)
    fam_rows.max_by do |r|
      [
        r.preferred ? 1 : 0,
        r.estimate_date.to_time.to_i,
        r.confidence_score.to_d,
        r.created_at.to_i
      ]
    end
  end

  def weighted_average(rows)
    pairs = rows.filter_map do |r|
      t = target_in_asset_ccy(r)
      next if t.nil?

      w = r.confidence_score.present? ? r.confidence_score.to_d : 1.to_d
      [t, w]
    end
    return nil if pairs.empty?

    wsum = pairs.sum { |_t, w| w }
    return nil if wsum.zero?

    pairs.sum { |t, w| t * w } / wsum
  end

  def nearest_to_current(sorted_targets)
    return nil if sorted_targets.empty? || @current_price.nil?

    sorted_targets.min_by { |t| (t - @current_price).abs }
  end

  def median(sorted)
    return nil if sorted.empty?

    n = sorted.size
    mid = n / 2
    if n.odd?
      sorted[mid]
    else
      (sorted[mid - 1] + sorted[mid]) / 2
    end
  end

  def upside(target)
    return nil if target.nil? || @current_price.nil? || @current_price.zero?

    ((target / @current_price) - 1) * 100
  end

  def target_in_asset_ccy(row)
    return nil if row.target_price.blank?

    t = row.target_price.to_d
    return t if row.currency_id == @asset.currency_id

    CurrencyConversionService.convert(t, row.currency_id, @asset.currency_id)
  rescue StandardError
    nil
  end

  def latest_price
    @asset.asset_prices
          .where(currency_id: @asset.currency_id)
          .order(date: :desc)
          .first&.price&.to_d
  end

  def horizon_order(h)
    AssetEstimate::HORIZON_TYPES.index(h) || 99
  end
end
