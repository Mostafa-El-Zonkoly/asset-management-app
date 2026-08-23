# frozen_string_literal: true

# Compares two assets on a common timeline.
#
# Chart normalization:
# - The plotted series are the cumulative % change from the *first aligned*
#   price point in the interval:
#   ((price_t / price_0) - 1) * 100 (%).
#
# Summary numbers:
# - `interval_changes` matches the overall % change over the selected interval
#   (last vs first).
#
# `weekly` — one point per ISO week (Mon–Sun): each asset uses its **last** price
#   observed in that week. Use this for funds that quote Sun/Thu vs daily ETFs.
#   If no ISO week contains a quote for **both** assets, we fall back to `calendar`.
# `calendar` — each **quote date** where either asset has a print; missing side
#   is last-observation-carried-forward (LOCF). Can look unfair when cadences differ.
class AssetCompareService
  ALIGNMENTS = %w[auto calendar weekly].freeze

  class << self
    def payload(asset_a, asset_b, range_key, alignment: "auto")
      new(asset_a, asset_b, range_key, alignment: alignment).payload
    end
  end

  def initialize(asset_a, asset_b, range_key, alignment: "auto")
    @asset_a = asset_a
    @asset_b = asset_b
    @range_key = range_key
    @alignment = normalize_alignment(alignment)
  end

  def payload
    range = ChartRangeHelper.range(@range_key)
    a = price_points(@asset_a, range)
    b = price_points(@asset_b, range)
    return empty_payload if a.empty? || b.empty?

    effective_alignment = effective_alignment_for(range, a.length, b.length)
    merged, calendar_fallback = build_merged(a, b, effective_alignment)
    return empty_payload if merged.empty?

    base_a = merged.first[:a].to_d
    base_b = merged.first[:b].to_d
    return empty_payload if base_a.zero? || base_b.zero?

    labels = merged.map { |r| r[:date].iso8601 }
    prices_a = merged.map { |r| r[:a].to_d }
    prices_b = merged.map { |r| r[:b].to_d }

    # Cumulative % change from the first aligned price.
    data_a = prices_a.map { |p| ((p / base_a) - 1).to_f * 100.0 }
    data_b = prices_b.map { |p| ((p / base_b) - 1).to_f * 100.0 }

    alignment_out = calendar_fallback ? "calendar" : effective_alignment
    note = calendar_fallback ? "No common ISO week; using each quote date (LOCF) instead." : nil

    {
      labels: labels,
      datasets: [
        { label: @asset_a.code, data: data_a, borderColor: "rgb(59, 130, 246)" },
        { label: @asset_b.code, data: data_b, borderColor: "rgb(234, 88, 12)" }
      ],
      interval_changes: [
        { label: @asset_a.code, pct_change: data_a.last },
        { label: @asset_b.code, pct_change: data_b.last }
      ],
      alignment: alignment_out,
      alignment_requested: (@alignment == "auto" ? effective_alignment : @alignment),
      alignment_note: note,
      y_axis_label: y_axis_label_for_response(calendar_fallback, effective_alignment),
      empty_hint: nil
    }
  end

  private

  def effective_alignment_for(range, a_count, b_count)
    return "weekly" unless @alignment == "auto"
    return "weekly" unless range

    days = (range.end - range.begin).to_i + 1
    return "weekly" if days <= 0

    # If both assets are “dense” over the selected window, prefer plotting every quote date.
    # Otherwise, bucket to weekly last-price to avoid daily-vs-Sun/Thu cadence distortion.
    density_threshold = days * 0.35
    if a_count >= density_threshold && b_count >= density_threshold
      "calendar"
    else
      "weekly"
    end
  end

  def build_merged(series_a, series_b, alignment)
    if alignment == "weekly"
      m = merge_weekly_last_in_week(series_a, series_b)
      return [ m, false ] if m.any?

      m = merge_forward_fill_on_quote_dates(series_a, series_b)
      return [ m, false ] if m.empty?

      return [ m, true ]
    end

    [ merge_forward_fill_on_quote_dates(series_a, series_b), false ]
  end

  def normalize_alignment(value)
    s = value.to_s
    ALIGNMENTS.include?(s) ? s : "auto"
  end

  def y_axis_label_for_response(calendar_fallback, effective_alignment)
    # Curve is cumulative % change from the first aligned price.
    if calendar_fallback || effective_alignment == "calendar"
      "% change from first overlapping quote date"
    else
      "% change from first overlapping week"
    end
  end

  # Used when there is no chart data at all (not calendar vs weekly).
  def y_axis_label_empty
    "% change from first aligned price"
  end

  def price_points(asset, date_range)
    scope = priced_scope_for(asset)
    scope = scope.where(date: date_range) if date_range
    scope.order(:date).pluck(:date, :price).map { |d, p| [ normalize_date(d), p ] }
  end

  def priced_scope_for(asset)
    scoped = asset.asset_prices.where(currency_id: asset.currency_id)
    return scoped if scoped.exists?

    asset.asset_prices
  end

  def normalize_date(value)
    return value if value.is_a?(Date)
    return value.to_date if value.respond_to?(:to_date)

    Date.iso8601(value.to_s)
  end

  # Union of dates where at least one asset has a price; LOCF each side.
  def merge_forward_fill_on_quote_dates(series_a, series_b)
    map_a = series_a.to_h
    map_b = series_b.to_h
    dates = (map_a.keys | map_b.keys).sort
    return [] if dates.empty?

    last_a = last_b = nil
    out = []
    dates.each do |d|
      last_a = map_a[d] if map_a.key?(d)
      last_b = map_b[d] if map_b.key?(d)
      next unless last_a && last_b

      out << { date: d, a: last_a, b: last_b }
    end
    out
  end

  # One row per ISO week where both assets have at least one quote that week.
  # Price = last print in that Mon–Sun window (handles Sun + Thu funds vs daily).
  def merge_weekly_last_in_week(series_a, series_b)
    wa = last_price_per_week(series_a)
    wb = last_price_per_week(series_b)
    (wa.keys & wb.keys).sort.map do |week_start|
      week_end = week_start.end_of_week(:monday)
      { date: week_end, a: wa[week_start], b: wb[week_start] }
    end
  end

  def last_price_per_week(series)
    by_week = Hash.new { |h, k| h[k] = [] }
    series.each do |date, price|
      ws = date.beginning_of_week(:monday)
      by_week[ws] << [ date, price ]
    end
    by_week.each_with_object({}) do |(ws, pairs), h|
      h[ws] = pairs.max_by(&:first).last
    end
  end

  def empty_payload
    {
      labels: [],
      datasets: [],
      interval_changes: [],
      alignment: @alignment,
      alignment_requested: nil,
      alignment_note: nil,
      y_axis_label: y_axis_label_empty,
      empty_hint:
        "Try a wider range (3M / 1Y), confirm both assets have prices in that window, " \
        "and that stored prices use the asset’s currency (or switch alignment to “Each quote date”)."
    }
  end
end
