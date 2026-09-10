# frozen_string_literal: true

require "bigdecimal"

# The Base vs Temporary analytical split for a single holding. This does NOT
# create a second holding — it derives a breakdown that always reconciles with
# the existing totals:
#   * Temporary is taken from the FIFO lot ledger (temporary lots' remaining qty);
#   * Base is the residual (total - temporary), so base_qty + temp_qty = total_qty
#     and base_value + temp_value = total_value EXACTLY.
# Cost basis is split by the temporary lots' cost share, so base_cost + temp_cost
# equals the existing cost basis while still reflecting the distinct lot prices.
# Quantities/values are 0 for watchlist holdings (quantity 0).
class PositionRoleService
  ROLES = %w[all base temporary].freeze

  Split = Struct.new(
    :total_qty, :base_qty, :temp_qty,
    :total_value, :base_value, :temp_value,
    :total_cost, :base_cost, :temp_cost,
    :total_unrealised, :base_unrealised, :temp_unrealised,
    :base_pct, :temp_pct,
    :base_avg_local, :temp_avg_local,
    keyword_init: true
  )

  class << self
    def for_holding(holding, calc: nil)
      new.for_holding(holding, calc: calc)
    end

    # Market value attributable to a role ("all" | "base" | "temporary").
    def value_for(holding, role, calc: nil)
      return (calc || HoldingsCalculatorService.for_holding(holding)).current_value.to_d if role.to_s == "all"

      s = for_holding(holding, calc: calc)
      role.to_s == "temporary" ? s.temp_value : s.base_value
    end

    def qty_for(holding, role)
      total = holding.quantity.to_d
      return total if role.to_s == "all"

      s = for_holding(holding)
      role.to_s == "temporary" ? s.temp_qty : s.base_qty
    end
  end

  def for_holding(holding, calc: nil)
    total_qty = holding.quantity.to_d
    calc ||= HoldingsCalculatorService.for_holding(holding)

    if total_qty <= 0
      return Split.new(
        total_qty: 0.to_d, base_qty: 0.to_d, temp_qty: 0.to_d,
        total_value: calc.current_value.to_d, base_value: 0.to_d, temp_value: 0.to_d,
        total_cost: calc.cost_basis.to_d, base_cost: 0.to_d, temp_cost: 0.to_d,
        total_unrealised: calc.unrealised_gain.to_d, base_unrealised: 0.to_d, temp_unrealised: 0.to_d,
        base_pct: 0.to_d, temp_pct: 0.to_d, base_avg_local: nil, temp_avg_local: nil
      )
    end

    temp_lots = AssetLot.where(portfolio_id: holding.portfolio_id, asset_id: holding.asset_id).temporary
    temp_qty = clamp(temp_lots.sum(:remaining_quantity).to_d, 0.to_d, total_qty)
    base_qty = total_qty - temp_qty

    total_value = calc.current_value.to_d
    total_cost = calc.cost_basis.to_d
    total_unrealised = calc.unrealised_gain.to_d

    # Value splits by quantity (same current price per share).
    temp_value = total_value * (temp_qty / total_qty)
    base_value = total_value - temp_value

    # Cost splits by lot cost share (asset-currency), preserving distinct lot prices.
    avg = holding.average_buy_price&.to_d || 0.to_d
    total_cost_local = avg * total_qty
    temp_cost_local = temp_lots.sum("remaining_quantity * buy_price_per_unit").to_d
    temp_cost_local = clamp(temp_cost_local, 0.to_d, total_cost_local) if total_cost_local.positive?
    share = total_cost_local.positive? ? (temp_cost_local / total_cost_local) : (temp_qty / total_qty)
    temp_cost = total_cost * share
    base_cost = total_cost - temp_cost
    base_cost_local = total_cost_local - temp_cost_local

    Split.new(
      total_qty: total_qty, base_qty: base_qty, temp_qty: temp_qty,
      total_value: total_value, base_value: base_value, temp_value: temp_value,
      total_cost: total_cost, base_cost: base_cost, temp_cost: temp_cost,
      total_unrealised: total_unrealised,
      base_unrealised: base_value - base_cost,
      temp_unrealised: temp_value - temp_cost,
      base_pct: (base_qty / total_qty) * 100,
      temp_pct: (temp_qty / total_qty) * 100,
      base_avg_local: base_qty.positive? ? (base_cost_local / base_qty) : nil,
      temp_avg_local: temp_qty.positive? ? (temp_cost_local / temp_qty) : nil
    )
  end

  private

  def clamp(v, lo, hi)
    [[v, lo].max, hi].min
  end
end
