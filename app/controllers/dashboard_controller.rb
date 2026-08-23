# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    @portfolios = Portfolio.order(:name)
    @portfolio =
      if params[:portfolio_id].present?
        @portfolios.find_by(id: params[:portfolio_id]) || @portfolios.first
      else
        @portfolios.first
      end
    @reporting_currency = Currency.base.first
    @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
    @wallet_cash_reporting = PortfolioStatsService.total_wallet_balance_reporting
    @free_cash_metrics = PortfolioStatsService.free_cash_target_metrics
    if @portfolios.any?
      @overall_stats = PortfolioStatsService.overall_summary
      non_emergency = @portfolios.where.not(whole_target_percentage: nil)
      @overall_xirr = PortfolioXirrService.overall(non_emergency)
      @overall_xirr_with_emergency = PortfolioXirrService.overall(@portfolios)
    end
    if @portfolio
      @stats = PortfolioStatsService.summary(@portfolio)
      @allocation = PortfolioStatsService.category_allocation(@portfolio)
      @portfolio_xirr = PortfolioXirrService.call(@portfolio)
    end
    @recent = PortfolioTransaction.includes(:portfolio, :asset, :transaction_type).order(date: :desc).limit(15)
  end
end
