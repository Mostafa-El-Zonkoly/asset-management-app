# frozen_string_literal: true

# One row per asset that has a positive quantity in at least one portfolio (non-wallet holdings).
class AssetSummaryService
  Row = Struct.new(
    :asset,
    :quantity,
    :current_value,
    :total_gain_pct,
    :weight_pct,
    :portfolio_names,
    :type_descriptor,
    keyword_init: true
  )

  class << self
    def call
      new.call
    end
  end

  def call
    reporting = Currency.base.first
    holdings_scope = Holding.joins(asset: :asset_type).merge(Asset.active).where("holdings.quantity > 0")
      .where.not(asset_types: { key: "wallet" })
      .includes(:portfolio, asset: %i[asset_type currency stock_purpose sector speciality
                                        fund_type fund_style management_style market_index])
    grouped = holdings_scope.group_by(&:asset_id)

    aggregates =
      grouped.map do |_asset_id, hs|
        asset = hs.first.asset
        calcs = hs.map { |h| HoldingsCalculatorService.for_holding(h) }
        {
          asset: asset,
          quantity: hs.sum { |h| h.quantity.to_d },
          current_value: calcs.sum(&:current_value),
          cost: calcs.sum(&:cost_basis),
          total_gain: calcs.sum(&:total_gain),
          portfolio_names: hs.map { |h| h.portfolio.name }.uniq.sort.join(", "),
          type_descriptor: type_descriptor_for(asset)
        }
      end

    grand_total_value = aggregates.sum { |a| a[:current_value] }

    rows =
      aggregates.map do |a|
        weight_pct =
          if grand_total_value.nonzero?
            (a[:current_value] / grand_total_value) * 100
          end

        Row.new(
          asset: a[:asset],
          quantity: a[:quantity],
          current_value: a[:current_value],
          total_gain_pct: gain_percent(a[:total_gain], a[:cost]),
          weight_pct: weight_pct,
          portfolio_names: a[:portfolio_names],
          type_descriptor: a[:type_descriptor]
        )
      end

    rows.sort_by! { |r| r.asset.code.downcase }

    { rows: rows, reporting_currency: reporting }
  end

  private

  def gain_percent(total_gain, cost_basis)
    return nil if cost_basis.nil?

    cb = cost_basis.to_d
    return ((total_gain.to_d / cb) * 100) if cb.nonzero?
    return 100.to_d if total_gain.to_d.positive?
    return -100.to_d if total_gain.to_d.negative?

    0.to_d
  end

  def type_descriptor_for(asset)
    parts = []
    parts << asset.asset_type&.label
    parts << asset.stock_purpose&.label
    parts << asset.sector&.label
    parts << asset.speciality&.label
    parts << asset.fund_type&.label
    parts << asset.fund_style&.label
    parts << asset.management_style&.label
    parts << asset.market_index&.code
    parts.compact.map(&:presence).compact.join(" - ")
  end
end
