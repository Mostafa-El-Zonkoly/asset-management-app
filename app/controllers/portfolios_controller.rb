# frozen_string_literal: true

class PortfoliosController < ApplicationController
  before_action :set_portfolio, only: %i[show edit update destroy xirr toggle_active]

  def performance
    @portfolios = current_user.portfolios.order(:name)
    owned = @portfolios.ids
    raw = params[:portfolio_ids]
    raw = raw.to_s.split(",") if raw.is_a?(String)
    @selected_portfolio_ids = Array(raw).map(&:to_i).uniq & owned
    scope = @selected_portfolio_ids.present? ? @portfolios.where(id: @selected_portfolio_ids).to_a : @portfolios.to_a

    @position_role = position_role_param
    @metric = params[:metric] == "pnl" ? "pnl" : "pct"
    @chart_range = params[:range].presence || "3m"
    @reporting_currency = Currency.base.first
    @rows = PortfolioPerformanceService.table(scope, role: @position_role)
    @period_defs = PortfolioPerformanceService::PERIODS
  end

  def funding_plan
    @reporting_currency = Currency.base.first
    @amount = parse_amount_param(params[:amount])
    @plan = nil

    return unless params.key?(:amount)
    return if @amount.nil?

    if @amount.negative?
      flash.now[:alert] = "Amount must be zero or greater."
      return
    end

    @plan = PortfolioFundingPlanService.build(amount: @amount)
  end

  def custom_funding_plan
    @reporting_currency = Currency.base.first
    @portfolios = current_user.portfolios.where(include_in_combined_percent: true).order(:name)
    @plan = nil

    return unless params.key?(:amounts)

    raw_amounts = params[:amounts].to_unsafe_h rescue {}
    wallet_amount = parse_amount_param(params[:wallet_amount]) || 0
    amounts = raw_amounts.transform_values { |v| BigDecimal(v.to_s) rescue 0.to_d }

    @plan = PortfolioCustomFundingPlanService.build(amounts: amounts, wallet_amount: wallet_amount)
  end

  def monthly_flows
    @reporting_currency = Currency.base.first
    @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
    @monthly_flows = MonthlyCashFlowService.call
  end

  def zakaa_statistics
    data = ZakaaStatsService.call
    @reporting_currency = data[:reporting_currency]
    @missing_fx_codes = data[:missing_fx_codes]
    @zakaa = data
  end

  def statistics
    SnapshotAutoRecorder.run(current_user&.id)
    @reporting_currency = Currency.base.first
    @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
    @overall_stats = PortfolioStatsService.overall_summary
    @portfolio_rows = PortfolioStatsService.all_portfolios_detail_rows
    @portfolio_xirr_by_id = @portfolio_rows.each_with_object({}) do |row, h|
      h[row[:portfolio].id] = PortfolioXirrService.call(row[:portfolio])
    end
    @portfolio_sharpe_by_id = @portfolio_rows.each_with_object({}) do |row, h|
      h[row[:portfolio].id] = PortfolioSharpeService.call(row[:portfolio])
    end
    @invested_included_total = PortfolioStatsService.combined_percent_total_value
    @wallet_cash_reporting = PortfolioStatsService.total_wallet_balance_reporting
    @wealth_denominator_for_percent = PortfolioStatsService.wealth_total_for_share_percent(
      invested_total: @invested_included_total
    )
    @free_cash_metrics = PortfolioStatsService.free_cash_target_metrics
    non_emergency = @portfolio_rows.select { |row| row[:portfolio].whole_target_percentage.present? }.map { |row| row[:portfolio] }
    @overall_xirr = PortfolioXirrService.overall(non_emergency)
    @overall_xirr_with_emergency = PortfolioXirrService.overall(@portfolio_rows.map { |row| row[:portfolio] })
  end

  def sector_analysis
    set_portfolio_filter
    @reporting_currency = Currency.base.first
    @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
    @included_total = PortfolioStatsService.included_total_value(@selected_portfolio_ids.presence)
    @position_role = position_role_param
    @sector_rows = PortfolioStatsService.cross_portfolio_sector_analysis(@selected_portfolio_ids.presence, position_role: @position_role)
    @sectored_total = @sector_rows.sum { |r| r[:value] }
    @targets_by_sector_id = SectorTarget.all.index_by(&:sector_id)
    @total_target_pct = @targets_by_sector_id.values.sum { |t| t.target_percentage.to_d }
  end

  def sector_speciality_analysis
    set_portfolio_filter
    @reporting_currency = Currency.base.first
    @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
    @included_total = PortfolioStatsService.included_total_value(@selected_portfolio_ids.presence)
    @position_role = position_role_param
    @sector_groups = PortfolioStatsService.cross_portfolio_sector_speciality_analysis(@selected_portfolio_ids.presence, position_role: @position_role)
    @sectored_total = @sector_groups.sum { |g| g[:sector_total] }
  end

  def sector_detail
    set_portfolio_filter
    @position_role = position_role_param
    @sector = Sector.find(params[:sector_id])
    @reporting_currency = Currency.base.first
    @included_total = PortfolioStatsService.included_total_value(@selected_portfolio_ids.presence)
    @rows = PortfolioStatsService.sector_asset_detail(@sector, portfolio_ids: @selected_portfolio_ids.presence)
    @filter_total = @rows.sum { |r| r[:current_value] }
  end

  def sector_speciality_detail
    set_portfolio_filter
    @position_role = position_role_param
    @sector = Sector.find(params[:sector_id])
    @speciality = Speciality.find(params[:speciality_id])
    @reporting_currency = Currency.base.first
    @included_total = PortfolioStatsService.included_total_value(@selected_portfolio_ids.presence)
    @rows = PortfolioStatsService.sector_asset_detail(@sector, speciality: @speciality, portfolio_ids: @selected_portfolio_ids.presence)
    @filter_total = @rows.sum { |r| r[:current_value] }
  end

  def index
    @overall_stats = PortfolioStatsService.overall_summary
    @summaries_by_portfolio = PortfolioStatsService.summaries_by_portfolio
    @invested_included_total = PortfolioStatsService.combined_percent_total_value_from_rows(@summaries_by_portfolio)
    @wallet_cash_reporting = PortfolioStatsService.total_wallet_balance_reporting
    @wealth_denominator_for_percent = PortfolioStatsService.wealth_total_for_share_percent(
      invested_total: @invested_included_total
    )
    @free_cash_metrics = PortfolioStatsService.free_cash_target_metrics
    @reporting_currency = Currency.base.first
    @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
  end

  def show
    load_portfolio_show_data
  end

  def xirr
    @reporting_currency = Currency.base.first
    @xirr_breakdown = PortfolioXirrService.breakdown(@portfolio)
    @xirr_result = @xirr_breakdown.result
  end

  def new
    @portfolio = current_user.portfolios.new
  end

  def edit
  end

  def create
    @portfolio = current_user.portfolios.new(portfolio_params)
    if @portfolio.save
      redirect_to @portfolio, notice: "Portfolio created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @portfolio.update(portfolio_params)
      redirect_to @portfolio, notice: "Portfolio updated."
    elsif params[:portfolio_form_context] == "show"
      load_portfolio_show_data
      render :show, status: :unprocessable_entity
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @portfolio.destroy!
    redirect_to portfolios_path, notice: "Portfolio removed."
  end

  def toggle_active
    @portfolio.update(active: !@portfolio.active)
    state = @portfolio.active? ? "enabled" : "disabled"
    redirect_back fallback_location: portfolios_path, notice: "Portfolio #{@portfolio.name} #{state}."
  end

  private

  # Portfolio filter for the cross-portfolio analysis pages. Reads params[:portfolio_ids]
  # (array or comma string), keeps only ids the current user owns, and exposes:
  #   @portfolios             - options for the filter control
  #   @selected_portfolio_ids - validated selection (empty => all portfolios)
  def position_role_param
    r = params[:position_role].to_s
    %w[all base temporary].include?(r) ? r : "all"
  end

  def set_portfolio_filter
    @portfolios = current_user.portfolios.order(:name)
    owned = @portfolios.ids
    raw = params[:portfolio_ids]
    raw = raw.to_s.split(",") if raw.is_a?(String)
    @selected_portfolio_ids = Array(raw).map(&:to_i).uniq & owned
  end

  def set_portfolio
    @portfolio = current_user.portfolios.find_by(key: params[:id]) || current_user.portfolios.find(params[:id])
  end

  def load_portfolio_show_data
    @stats = PortfolioStatsService.summary(@portfolio)
    @allocation = PortfolioStatsService.category_allocation(@portfolio)
    @invested_included_total = PortfolioStatsService.combined_percent_total_value
    @wallet_cash_reporting = PortfolioStatsService.total_wallet_balance_reporting
    @wealth_denominator_for_percent = PortfolioStatsService.wealth_total_for_share_percent(
      invested_total: @invested_included_total
    )
    @whole_portfolio_target = PortfolioStatsService.whole_portfolio_target_metrics(
      @portfolio,
      combined_total_value: @wealth_denominator_for_percent
    )
    @reporting_currency = Currency.base.first
    @sectors = PortfolioStatsService.sector_breakdown(@portfolio)
    @holdings = @portfolio.holdings
      .includes(asset: [ :category, :asset_type, :currency ])
      .where.not(quantity: 0)
      .order("categories.name, assets.name")
    @targets = @portfolio.portfolio_targets.includes(:category, :target_type)
    @ms_allocation = PortfolioStatsService.management_style_allocation(@portfolio)
    @ms_targets = @portfolio.portfolio_management_style_targets.includes(:management_style, :target_type)
    @portfolio_xirr = PortfolioXirrService.call(@portfolio)
    @sharpe = PortfolioSharpeService.call(@portfolio)
    @perf = PortfolioPerformanceService.for_portfolio(@portfolio)
    @perf_period_defs = PortfolioPerformanceService::PERIODS
    @benchmark = @portfolio.benchmark_market_index
    if @benchmark && @perf.inception && @perf.as_of
      bounds = PortfolioPerformanceService.boundaries(as_of: @perf.as_of, inception: @perf.inception)
      @benchmark_returns = @perf_period_defs.to_h do |key, _l|
        b = bounds[key]
        pct = b ? IndexReturnService.percent(@benchmark, from: b, to: @perf.as_of) : nil
        [key, pct]
      end
    end
  end

  def portfolio_params
    params.require(:portfolio).permit(
      :name, :key, :description,
      :include_in_combined_percent, :active,
      :whole_target_type_id, :whole_target_percentage, :whole_target_amount,
      :benchmark_market_index_id
    )
  end

  def parse_amount_param(raw)
    return nil if raw.blank?

    BigDecimal(raw.to_s)
  rescue ArgumentError
    flash.now[:alert] = "Enter a valid numeric amount."
    nil
  end
end
