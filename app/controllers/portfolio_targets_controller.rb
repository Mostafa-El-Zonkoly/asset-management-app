# frozen_string_literal: true

class PortfolioTargetsController < ApplicationController
  before_action :set_portfolio

  def create
    @target = @portfolio.portfolio_targets.build(target_params)
    if @target.save
      redirect_to portfolio_path(@portfolio), notice: "Target added."
    else
      redirect_to portfolio_path(@portfolio), alert: @target.errors.full_messages.to_sentence
    end
  end

  def update
    @target = @portfolio.portfolio_targets.find(params[:id])
    if @target.update(target_params)
      redirect_to portfolio_path(@portfolio), notice: "Target updated."
    else
      redirect_to portfolio_path(@portfolio), alert: @target.errors.full_messages.to_sentence
    end
  end

  def destroy
    @target = @portfolio.portfolio_targets.find(params[:id])
    @target.destroy!
    redirect_to portfolio_path(@portfolio), notice: "Target removed."
  end

  private

  def set_portfolio
    @portfolio = Portfolio.find(params[:portfolio_id])
  end

  def target_params
    params.require(:portfolio_target).permit(:category_id, :target_type_id, :target_percentage, :target_amount)
  end
end
