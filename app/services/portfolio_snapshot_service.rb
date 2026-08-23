# frozen_string_literal: true

class PortfolioSnapshotService
  class << self
    def record!(portfolio, as_of: Date.current)
      new.record!(portfolio, as_of: as_of)
    end

    def record_all!(as_of: Date.current)
      Portfolio.find_each { |p| record!(p, as_of: as_of) }
    end
  end

  def record!(portfolio, as_of:)
    stats = PortfolioStatsService.summary(portfolio)
    snap = PortfolioSnapshot.find_or_initialize_by(portfolio_id: portfolio.id, date: as_of)
    snap.total_value = stats[:total_value]
    snap.currency_id = Currency.reporting_currency_id || Currency.order(:id).first!.id
    snap.save!
  end
end
