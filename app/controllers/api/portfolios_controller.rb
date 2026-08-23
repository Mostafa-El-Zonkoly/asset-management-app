# frozen_string_literal: true

module Api
  class PortfoliosController < ApplicationController
    def performance
      portfolio = current_user.portfolios.find(params[:id])
      range = ChartRangeHelper.range(params[:range] || "1m")
      scope = portfolio.portfolio_snapshots.order(:date)
      scope = scope.where(date: range) if range
      data = scope.pluck(:date, :total_value).map { |d, v| { date: d.iso8601, value: v.to_f } }
      render json: data
    end

    def allocation
      portfolio = current_user.portfolios.find(params[:id])
      render json: PortfolioStatsService.category_allocation(portfolio)
    end

    def sector_breakdown
      portfolio = current_user.portfolios.find(params[:id])
      render json: PortfolioStatsService.sector_breakdown(portfolio)
    end
  end
end
