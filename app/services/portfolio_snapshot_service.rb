# frozen_string_literal: true

require "bigdecimal"

class PortfolioSnapshotService
  HALF = BigDecimal("0.5")

  class << self
    def record!(portfolio, as_of: Date.current)
      new.record!(portfolio, as_of: as_of)
    end

    def record_all!(as_of: Date.current)
      Portfolio.find_each { |p| record!(p, as_of: as_of) }
    end

    # Recompute the daily Modified Dietz chain (external flows, dividend income,
    # daily_return, daily_pnl, invested_value) over a portfolio's STORED snapshot
    # value series. Because it reads stored total_values and frozen transactions,
    # historical returns never change when live prices update.
    def enrich_returns!(portfolio, base_id: nil)
      new.enrich_returns!(portfolio, base_id: base_id)
    end
  end

  def record!(portfolio, as_of:)
    stats = PortfolioStatsService.summary(portfolio)
    snap = PortfolioSnapshot.find_or_initialize_by(portfolio_id: portfolio.id, date: as_of)
    snap.total_value = stats[:total_value]
    snap.currency_id = Currency.reporting_currency_id || Currency.order(:id).first!.id
    snap.save!
    enrich_returns!(portfolio)
    snap
  end

  def enrich_returns!(portfolio, base_id: nil)
    base_id ||= Currency.reporting_currency_id
    snaps = PortfolioSnapshot.where(portfolio_id: portfolio.id).order(:date).to_a
    return if snaps.empty?

    flows = PortfolioCashFlowService.for_portfolio(portfolio, base_id: base_id)
    prev = nil
    cumulative_invested = 0.to_d

    snaps.each do |s|
      window = flow_window(flows, prev&.date, s.date)
      f = window.external
      div = window.dividend
      cumulative_invested += f

      s.external_cash_flow = f
      s.dividend_income = div
      s.invested_value = cumulative_invested

      if prev.nil?
        s.daily_return = nil
        s.daily_pnl = nil
      else
        start = prev.total_value.to_d
        endv = s.total_value.to_d
        pnl = endv - start - f + div
        denom = start + (f * HALF)
        s.daily_pnl = pnl
        s.daily_return = denom.zero? ? nil : (pnl / denom)
      end

      s.save!(validate: false) if s.changed?
      prev = s
    end
  end

  private

  # Sum external + dividend flows for dates in (from_exclusive, to_inclusive].
  # from_exclusive nil => all dates on or before to_inclusive (inception window).
  def flow_window(flows, from_exclusive, to_inclusive)
    ext = 0.to_d
    div = 0.to_d
    flows.each do |d, day|
      next if from_exclusive && d <= from_exclusive
      next if d > to_inclusive

      ext += day.external
      div += day.dividend
    end
    PortfolioCashFlowService::Day.new(external: ext, dividend: div)
  end
end
