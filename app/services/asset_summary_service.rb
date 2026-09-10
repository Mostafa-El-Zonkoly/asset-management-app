# frozen_string_literal: true

# One row per asset that has a positive quantity in at least one portfolio (non-wallet holdings).
class AssetSummaryService
  Row = Struct.new(
    :asset,
    :quantity,
    :current_value,
    :total_gain_pct,
    :weight_pct,
    :base_value,
    :temp_value,
    :base_pct,
    :temp_pct,
    :portfolio_names,
    :type_descriptor,
    keyword_init: true
  )

  class << self
    def call(asset_type_key: nil, position_role: "all")
      new.call(asset_type_key: asset_type_key, position_role: position_role)
    end
  end

  def call(asset_type_key: nil, position_role: "all")
    role = position_role.to_s
    reporting = Currency.base.first
    holdings_scope = Holding.joins(asset: :asset_type).merge(Asset.active).where("holdings.quantity > 0")
      .where.not(asset_types: { key: "wallet" })
      .includes(:portfolio, asset: %i[asset_type currency stock_purpose sector speciality
                                        fund_type fund_style management_style market_index])
    holdings_scope = holdings_scope.where(asset_types: { key: asset_type_key }) if asset_type_key.present?
    grouped = holdings_scope.group_by(&:asset_id)

    aggregates =
      grouped.filter_map do |_asset_id, hs|
        asset = hs.first.asset
        calcs = hs.map { |h| HoldingsCalculatorService.for_holding(h) }
        splits = hs.each_index.map { |i| PositionRoleService.for_holding(hs[i], calc: calcs[i]) }
        slices = hs.each_index.map { |i| role_slice(hs[i], calcs[i], role) }
        quantity = role == "all" ? hs.sum { |h| h.quantity.to_d } : slices.sum { |sl| sl[3] }
        next if role != "all" && quantity <= 0

        {
          asset: asset,
          quantity: quantity,
          current_value: role == "all" ? calcs.sum(&:current_value) : slices.sum { |sl| sl[0] },
          cost: role == "all" ? calcs.sum(&:cost_basis) : slices.sum { |sl| sl[1] },
          total_gain: role == "all" ? calcs.sum(&:total_gain) : slices.sum { |sl| sl[2] },
          base_value: splits.sum(&:base_value),
          temp_value: splits.sum(&:temp_value),
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

        split_total = a[:base_value] + a[:temp_value]

        Row.new(
          asset: a[:asset],
          quantity: a[:quantity],
          current_value: a[:current_value],
          total_gain_pct: gain_percent(a[:total_gain], a[:cost]),
          weight_pct: weight_pct,
          base_value: a[:base_value],
          temp_value: a[:temp_value],
          base_pct: split_total.nonzero? ? (a[:base_value] / split_total) * 100 : nil,
          temp_pct: split_total.nonzero? ? (a[:temp_value] / split_total) * 100 : nil,
          portfolio_names: a[:portfolio_names],
          type_descriptor: a[:type_descriptor]
        )
      end

    rows.sort_by! { |r| r.asset.code.downcase }

    { rows: rows, reporting_currency: reporting }
  end

  private

  def role_slice(holding, calc, role)
    if role == "all"
      [calc.current_value.to_d, calc.cost_basis.to_d, calc.total_gain.to_d, holding.quantity.to_d]
    else
      sp = PositionRoleService.for_holding(holding, calc: calc)
      if role == "temporary"
        [sp.temp_value, sp.temp_cost, sp.temp_unrealised, sp.temp_qty]
      else
        [sp.base_value, sp.base_cost, sp.base_unrealised, sp.base_qty]
      end
    end
  end

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
