# frozen_string_literal: true

class AssetsController < ApplicationController
  CHART_RANGE_KEYS = %w[cw cm cy 1w 1m 3m ytd 1y].freeze
  PRICE_ROWS_PER_PAGE = 25

  before_action :set_asset, only: %i[show edit update destroy fetch_price]

  def summary
    data = AssetSummaryService.call
    @rows = data[:rows]
    @reporting_currency = data[:reporting_currency]
  end

  def index
    @q = Asset.active.includes(:category, :asset_type, :currency, :sector).ransack(params[:q])
    @pagy, @assets = pagy(@q.result.order(:code), items: 25)
  end

  def performance
    @range_from, @range_to = parse_performance_range
    @rows = AssetDayPerformanceService.call(range_begin: @range_from, range_end: @range_to)
  end

  def compare
    list = Asset.active.order(:code).to_a
    @compare_assets = list
    @asset_a_id = params[:asset_a_id].presence
    @asset_b_id = params[:asset_b_id].presence

    if @asset_a_id.blank? && list.size >= 1
      @asset_a_id = list.first.id.to_s
    end
    if @asset_b_id.blank? && list.size >= 2
      @asset_b_id = list.second.id.to_s
    elsif @asset_b_id.blank? && list.size == 1
      @asset_b_id = list.first.id.to_s
    end

    @from = params[:from]
    @to = params[:to]
    @preset_range = params[:range].presence || "3m"
    @alignment = params[:alignment].presence_in(AssetCompareService::ALIGNMENTS) || "auto"
    @range_key = ChartRangeHelper.range_key_from_params(
      range: @preset_range,
      from: params[:from],
      to: params[:to]
    )
  end

  def show
    @stats = AssetStatsService.summary(@asset)
    @reporting_currency = Currency.base.first
    @holdings = @asset.holdings.includes(:portfolio, :asset).joins(:portfolio).order("portfolios.name")
    @transactions = PortfolioTransaction.where(asset: @asset).includes(:portfolio, :transaction_type).order(date: :desc).limit(50)
    @chart_range = resolved_chart_range_key(params[:chart_range])
    @chart_prices = AssetStatsService.price_series(@asset, range_key: @chart_range)
    sampled_chart_prices = sample_chart_prices_for_list(@chart_prices, @chart_range)
    @price_rows = build_price_rows(sampled_chart_prices)
    @prices_total_pages = [(@price_rows.size.to_f / PRICE_ROWS_PER_PAGE).ceil, 1].max
    @prices_page = params.fetch(:prices_page, 1).to_i.clamp(1, @prices_total_pages)
    @prices_page_rows = @price_rows.reverse.slice((@prices_page - 1) * PRICE_ROWS_PER_PAGE, PRICE_ROWS_PER_PAGE) || []
    @range_interval_pct = CHART_RANGE_KEYS.index_with do |key|
      series = AssetStatsService.price_series(@asset, range_key: key)
      AssetStatsService.interval_change_percent_for_series(series)
    end
  end

  def new
    @asset = Asset.new(active: true)
    load_form_collections
  end

  def edit
    load_form_collections
  end

  def create
    @asset = Asset.new(asset_params)
    if @asset.save
      redirect_to @asset, notice: "Asset created."
    else
      load_form_collections
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @asset.update(asset_params)
      redirect_to @asset, notice: "Asset updated."
    else
      load_form_collections
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @asset.destroy!
    redirect_to assets_path, notice: "Asset removed."
  end

  def fetch_price
    result = PriceFetcherService.fetch_one(@asset)

    if result[:ok]
      redirect_to @asset, notice: "Fetched price for #{@asset.code}: #{result[:price]} #{@asset.currency.code} (#{result[:date]})."
    else
      redirect_to @asset, alert: "Price fetch failed for #{@asset.code}: #{result[:error]}"
    end
  end

  private

  def parse_performance_range
    if params[:from].present? || params[:to].present?
      from_d = parse_date_param(params[:from]) || Date.current
      to_d = parse_date_param(params[:to]) || Date.current
    elsif params[:date].present?
      d = parse_date_param(params[:date]) || Date.current
      from_d = to_d = d
    else
      from_d = to_d = Date.current
    end

    if to_d < from_d
      [ to_d, from_d ]
    else
      [ from_d, to_d ]
    end
  end

  def parse_date_param(raw)
    return nil if raw.blank?

    Date.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  def set_asset
    identifier = params[:id].to_s
    @asset = Asset.find_by("LOWER(code) = ?", identifier.downcase) || Asset.find(identifier)
  end

  def load_form_collections
    @categories = Category.includes(:category_type).order(:name)
    @asset_types = AssetType.active.order(:position)
    @currencies = Currency.order(:code)
    @stock_purposes = StockPurpose.active.order(:position)
    @sectors = Sector.active.order(:position)
    @specialities = Speciality.active.includes(:sector).order(:position)
    @fund_types = FundType.active.order(:position)
    @fund_styles = FundStyle.active.order(:position)
    @management_styles = ManagementStyle.active.order(:position)
    @market_indices = MarketIndex.order(:code)
  end

  def asset_params
    params.require(:asset).permit(
      :name, :code, :category_id, :asset_type_id, :currency_id,
      :stock_purpose_id, :sector_id, :speciality_id,
      :fund_type_id, :fund_style_id, :management_style_id, :market_index_id,
      :static_target, :zaka_percentage, :notes, :active,
      :price_provider, :price_provider_key, :price_provider_link,
      :core_candidate, :entry_score, :quality_score, :catalyst_score,
      :catalyst_note, :sharia_score_override
    )
  end

  def build_price_rows(rows)
    rows.each_with_index.map do |row, idx|
      current_price = row[:price]&.to_d
      previous_price = idx.positive? ? rows[idx - 1][:price]&.to_d : nil
      change = current_price && previous_price ? current_price - previous_price : nil
      change_pct = if change && previous_price&.nonzero?
                     (change / previous_price) * 100
                   end

      row.merge(change: change, change_pct: change_pct)
    end
  end

  def sample_chart_prices_for_list(rows, range_key)
    granularity = list_granularity_for_range(range_key)
    return rows if granularity == :day

    rows.group_by do |row|
      date = Date.parse(row[:date].to_s)
      case granularity
      when :week then date.beginning_of_week(:sunday)
      when :month then date.beginning_of_month
      end
    end.values.map(&:last)
  end

  def list_granularity_for_range(range_key)
    key = range_key.to_s
    return :day if %w[cw 1w].include?(key)
    return :week if %w[cm 1m 3m].include?(key)
    return :month if %w[ytd cy 1y].include?(key)

    return :week unless custom_range_key?(key)

    custom_days = (ChartRangeHelper.range(key).end - ChartRangeHelper.range(key).begin).to_i
    custom_days > 180 ? :month : :week
  end

  def resolved_chart_range_key(raw_range)
    key = raw_range.to_s
    return key if CHART_RANGE_KEYS.include?(key)
    return key if custom_range_key?(key)

    "3m"
  end

  def custom_range_key?(key)
    return false unless key.include?("..")

    ChartRangeHelper.range(key)
    true
  rescue ArgumentError
    false
  end
end
