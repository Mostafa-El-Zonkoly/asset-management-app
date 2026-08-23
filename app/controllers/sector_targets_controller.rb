# frozen_string_literal: true

class SectorTargetsController < ApplicationController
  before_action :set_sector

  def create
    @target = @sector.build_sector_target(target_percentage: params[:target_percentage])
    if @target.save
      redirect_to sector_analysis_portfolios_path, notice: "Target set."
    else
      redirect_to sector_analysis_portfolios_path, alert: @target.errors.full_messages.to_sentence
    end
  end

  def update
    @target = @sector.sector_target || @sector.build_sector_target
    if @target.update(target_percentage: params[:target_percentage])
      redirect_to sector_analysis_portfolios_path, notice: "Target updated."
    else
      redirect_to sector_analysis_portfolios_path, alert: @target.errors.full_messages.to_sentence
    end
  end

  def destroy
    @sector.sector_target&.destroy
    redirect_to sector_analysis_portfolios_path, notice: "Target removed."
  end

  private

  def set_sector
    @sector = Sector.find(params[:sector_id])
  end
end
