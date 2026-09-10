# frozen_string_literal: true

class AssetEstimatesController < ApplicationController
  before_action :set_asset
  before_action :set_estimate, only: %i[edit update destroy]

  def index
    @q = @asset.asset_estimates.ransack(params[:q])
    @estimates = @q.result.chronological
    @currencies = Currency.order(:code)
    @summary = AssetEstimateSummaryService.call(@asset, exclude_stale: exclude_stale_param)
    @exclude_stale = exclude_stale_param
  end

  def new
    @estimate = @asset.asset_estimates.new(
      estimate_date: Date.current,
      currency_id: @asset.currency_id
    )
    @currencies = Currency.order(:code)
  end

  def edit
    @currencies = Currency.order(:code)
  end

  def create
    @estimate = @asset.asset_estimates.new(estimate_params)
    if @estimate.save
      redirect_to asset_estimates_path(@asset), notice: "Estimate added."
    else
      @currencies = Currency.order(:code)
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @estimate.update(estimate_params)
      redirect_to asset_estimates_path(@asset), notice: "Estimate updated."
    else
      @currencies = Currency.order(:code)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @estimate.destroy!
    redirect_to asset_estimates_path(@asset), notice: "Estimate removed."
  end

  private

  def set_asset
    identifier = params[:asset_id].to_s
    @asset = Asset.find_by("LOWER(code) = ?", identifier.downcase) || Asset.find(identifier)
  end

  def set_estimate
    @estimate = @asset.asset_estimates.find(params[:id])
  end

  def exclude_stale_param
    return true unless params.key?(:exclude_stale)

    ActiveModel::Type::Boolean.new.cast(params[:exclude_stale])
  end

  def estimate_params
    params.require(:asset_estimate).permit(
      :source_name, :source_family, :estimate_type, :data_role,
      :horizon_type, :horizon_days, :estimate_date,
      :target_price, :target_min, :target_max, :currency_id,
      :confidence_score, :analyst_name, :notes, :reference_url,
      :preferred, :active
    )
  end
end
