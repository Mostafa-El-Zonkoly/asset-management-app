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

    def performance_series
      portfolios = current_user.portfolios.order(:name)
      ids = params[:portfolio_ids].to_s.split(",").map(&:to_i).reject(&:zero?)
      portfolios = portfolios.where(id: ids) if ids.present?
      role = %w[all base temporary].include?(params[:role].to_s) ? params[:role].to_s : "all"
      mode = params[:mode].to_s == "common" ? "common" : "own"
      benchmark = ActiveModel::Type::Boolean.new.cast(params[:benchmark])
      range = ChartRangeHelper.range(params[:range] || "3m")
      from = range&.begin || Date.new(1900, 1, 1)
      result = PortfolioPerformanceService.normalized_series(
        portfolios.to_a, role: role, from: from, to: Date.current, mode: mode, benchmark: benchmark
      )
      render json: { common_start: result[:common_start], mode: mode, series: result[:series] }
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
