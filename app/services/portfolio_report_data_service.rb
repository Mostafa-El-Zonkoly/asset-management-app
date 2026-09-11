# frozen_string_literal: true

require "bigdecimal"

# Assembles ALL report data from the existing calculation services (spec AN/AR:
# one source of truth — the PDF renderer only formats this, it never recomputes
# accounting). Supports Full (all portfolios) or Filtered (a portfolio and/or a
# Position Role) scope. Watchlist rows (qty 0) are excluded from holdings and
# exposure totals (spec AF/Y/AA/AB).
class PortfolioReportDataService
  # Concentration thresholds (spec AC). Only applied to CALCULATED exposures.
  STOCK_WATCH = 12.0
  STOCK_MAX = 15.0
  SECTOR_SOFT = 25.0
  SECTOR_HARD = 30.0
  SUBSECTOR_WATCH = 10.0
  SUBSECTOR_HIGH = 15.0
  SUBSECTOR_SEVERE = 20.0

  class << self
    def call(scope: :full, portfolio: nil, position_role: "all")
      new(scope: scope, portfolio: portfolio, position_role: position_role).call
    end
  end

  def initialize(scope:, portfolio:, position_role:)
    @scope = scope
    @portfolio = portfolio
    @role = position_role.to_s
    @base_id = Currency.reporting_currency_id
  end

  def call
    portfolios = @portfolio ? [@portfolio] : Portfolio.order(:name).to_a
    master = PortfolioMasterAccountingService.call(portfolios, base_id: @base_id)
    holdings = build_holdings(portfolios)
    equity_total = holdings.sum { |h| h[:market_value] }

    {
      generated_at: Time.current,
      prices_as_of: AssetPrice.maximum(:date),
      reporting_currency: Currency.base.first&.code,
      scope: @scope,
      filters: active_filters,
      master: master,
      sleeves: build_sleeves(master, holdings),
      holdings: holdings,
      equity_total: equity_total,
      combined_exposure: combined_exposure(holdings, equity_total),
      sectors: allocation(holdings, :sector, equity_total),
      subsectors: allocation(holdings, :subsector, equity_total),
      position_role: position_role_totals(holdings),
      cash_by_portfolio: master.rows.map { |r| { name: r.portfolio.name, cash: r.cash, nav: r.nav } },
      recent_flows: recent_flows(portfolios),
      warnings: concentration_warnings(holdings, equity_total),
      watchlist: watchlist_rows(portfolios)
    }
  end

  private

  def active_filters
    f = {}
    f["Portfolio"] = @portfolio.name if @portfolio
    f["Position role"] = @role.capitalize unless @role == "all"
    f
  end

  def build_holdings(portfolios)
    rows = []
    portfolios.each do |p|
      p.holdings.includes(asset: %i[sector speciality asset_type stock_purpose]).where.not(quantity: 0).find_each do |h|
        next if h.asset.wallet?

        calc = HoldingsCalculatorService.for_holding(h)
        sp = PositionRoleService.for_holding(h, calc: calc)
        qty = role_qty(h, sp)
        next if qty <= 0

        mv = role_mv(calc, sp)
        rows << {
          portfolio: p.name, ticker: h.asset.code, name: h.asset.name,
          sector: h.asset.sector&.label || "—", subsector: h.asset.speciality&.label || "—",
          quantity: qty, base_qty: sp.base_qty, temp_qty: sp.temp_qty,
          avg_cost: h.average_buy_price&.to_d, current_price: calc.current_price&.to_d,
          market_value: mv, unrealised: calc.unrealised_gain.to_d, unrealised_pct: calc.unrealised_gain_pct.to_d,
          base_value: sp.base_value, temp_value: sp.temp_value, asset_id: h.asset_id
        }
      end
    end
    rows.sort_by { |r| -r[:market_value].to_f }
  end

  def role_qty(holding, sp)
    case @role
    when "base" then sp.base_qty
    when "temporary" then sp.temp_qty
    else holding.quantity.to_d
    end
  end

  def role_mv(calc, sp)
    case @role
    when "base" then sp.base_value
    when "temporary" then sp.temp_value
    else calc.current_value.to_d
    end
  end

  def build_sleeves(master, holdings)
    counts = holdings.group_by { |h| h[:portfolio] }.transform_values(&:size)
    master.rows.map do |r|
      {
        name: r.portfolio.name, nav: r.nav, holdings_value: r.holdings_value, cash: r.cash,
        weight: master.nav.positive? ? (r.nav / master.nav * 100) : 0.to_d,
        simple_roi: r.simple_roi, realized: r.realized_pnl, unrealized: r.unrealized_pnl,
        holdings_count: counts[r.portfolio.name] || 0,
        buy_turnover: r.buy_turnover, sell_turnover: r.sell_turnover
      }
    end
  end

  def combined_exposure(holdings, equity_total)
    holdings.group_by { |h| h[:ticker] }.map do |ticker, rows|
      qty = rows.sum { |r| r[:quantity] }
      mv = rows.sum { |r| r[:market_value] }
      { ticker: ticker, name: rows.first[:name], quantity: qty, market_value: mv,
        weight: equity_total.positive? ? (mv / equity_total * 100) : 0.to_d,
        sleeves: rows.map { |r| r[:portfolio] }.uniq.sort.join(", ") }
    end.sort_by { |r| -r[:market_value].to_f }
  end

  def allocation(holdings, key, equity_total)
    holdings.group_by { |h| h[key] }.map do |name, rows|
      mv = rows.sum { |r| r[:market_value] }
      { name: name, market_value: mv,
        weight: equity_total.positive? ? (mv / equity_total * 100) : 0.to_d,
        count: rows.map { |r| r[:ticker] }.uniq.size }
    end.sort_by { |r| -r[:market_value].to_f }
  end

  def position_role_totals(holdings)
    base = holdings.sum { |h| h[:base_value] }
    temp = holdings.sum { |h| h[:temp_value] }
    total = base + temp
    { base_value: base, temp_value: temp,
      base_pct: total.positive? ? (base / total * 100) : nil,
      temp_pct: total.positive? ? (temp / total * 100) : nil }
  end

  def recent_flows(portfolios)
    PortfolioCashFlow.where(portfolio_id: portfolios.map(&:id))
                     .includes(:portfolio, :currency, :counterparty_portfolio, :related_wallet)
                     .chronological.reverse_order.limit(20).to_a
  end

  def watchlist_rows(portfolios)
    Holding.where(portfolio_id: portfolios.map(&:id), quantity: 0)
           .includes(asset: %i[sector speciality]).map do |h|
      { ticker: h.asset.code, name: h.asset.name, sector: h.asset.sector&.label || "—",
        subsector: h.asset.speciality&.label || "—" }
    end.uniq { |r| r[:ticker] }
  end

  def concentration_warnings(holdings, equity_total)
    warnings = []
    combined_exposure(holdings, equity_total).each do |r|
      w = r[:weight].to_f
      if w > STOCK_MAX
        warnings << { level: "severe", scope: "Stock", name: r[:ticker], weight: r[:weight], note: "above #{STOCK_MAX}% exceptional maximum" }
      elsif w > STOCK_WATCH
        warnings << { level: "watch", scope: "Stock", name: r[:ticker], weight: r[:weight], note: "above #{STOCK_WATCH}% comfortable band" }
      end
    end
    allocation(holdings, :sector, equity_total).each do |r|
      w = r[:weight].to_f
      if w > SECTOR_HARD
        warnings << { level: "severe", scope: "Sector", name: r[:name], weight: r[:weight], note: "above #{SECTOR_HARD}% hard cap" }
      elsif w > SECTOR_SOFT
        warnings << { level: "watch", scope: "Sector", name: r[:name], weight: r[:weight], note: "above #{SECTOR_SOFT}% soft cap" }
      end
    end
    allocation(holdings, :subsector, equity_total).each do |r|
      w = r[:weight].to_f
      lvl = if w > SUBSECTOR_SEVERE then "severe"
            elsif w > SUBSECTOR_HIGH then "high"
            elsif w > SUBSECTOR_WATCH then "watch"
            end
      warnings << { level: lvl, scope: "Subsector", name: r[:name], weight: r[:weight], note: "concentration" } if lvl
    end
    warnings
  end
end
