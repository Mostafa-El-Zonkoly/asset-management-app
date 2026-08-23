# frozen_string_literal: true

module Settings
  class LookupsController < ApplicationController
    MODELS = {
      "asset_types" => AssetType,
      "stock_purposes" => StockPurpose,
      "sectors" => Sector,
      "specialities" => Speciality,
      "fund_types" => FundType,
      "fund_styles" => FundStyle,
      "management_styles" => ManagementStyle,
      "category_types" => CategoryType,
      "transaction_types" => TransactionType,
      "price_sources" => PriceSource,
      "target_types" => TargetType
    }.freeze

    def index
      @tables = MODELS.keys
      @reporting_currency = Currency.base.first
      @distribution_table = params[:distribution].presence
      if @distribution_table.present? &&
          LookupAssetDistributionService::TABLE_MODEL.key?(@distribution_table)
        @distribution = LookupAssetDistributionService.build(@distribution_table)
        @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
      else
        @distribution_table = nil
        @distribution = nil
      end
    end

    def show
      @model = model!
      @records = @model.order(:position, :label)
    end

    def distribution
      table = params[:table]
      unless LookupAssetDistributionService::TABLE_MODEL.key?(table)
        redirect_to settings_lookups_path, alert: "Unknown distribution table."
        return
      end
      @table = table
      @distribution = LookupAssetDistributionService.build(table)
      @reporting_currency = Currency.base.first
      @missing_fx_codes = PortfolioStatsService.missing_fx_currency_codes_for_reporting
    end

    def new
      @model = model!
      @record = @model.new(active: true)
      load_sector_for_speciality
    end

    def create
      @model = model!
      @record = @model.new(lookup_params_for(@model))
      if @record.save
        redirect_to settings_lookup_table_path(params[:table]), notice: "Row created."
      else
        load_sector_for_speciality
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @model = model!
      @record = @model.find(params[:id])
      load_sector_for_speciality
    end

    def update
      @model = model!
      @record = @model.find(params[:id])
      if @record.update(lookup_params_for(@model))
        redirect_to settings_lookup_table_path(params[:table]), notice: "Row updated."
      else
        load_sector_for_speciality
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @model = model!
      @record = @model.find(params[:id])
      @record.destroy!
      redirect_to settings_lookup_table_path(params[:table]), notice: "Row removed."
    end

    private

    def model!
      MODELS.fetch(params[:table])
    end

    def load_sector_for_speciality
      @sectors = Sector.active.order(:position) if @model == Speciality
    end

    def lookup_params_for(model)
      base = %i[key label position active]
      base << :sector_id if model == Speciality
      params.require(model.model_name.param_key).permit(*base)
    end
  end
end
