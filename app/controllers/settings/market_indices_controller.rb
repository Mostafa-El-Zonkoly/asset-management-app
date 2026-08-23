# frozen_string_literal: true

module Settings
  class MarketIndicesController < ApplicationController
    before_action :set_index, only: %i[edit update destroy]

    def index
      @indices = MarketIndex.includes(:currency).order(:code)
    end

    def new
      @market_index = MarketIndex.new
      @currencies = Currency.order(:code)
    end

    def edit
      @currencies = Currency.order(:code)
    end

    def create
      @market_index = MarketIndex.new(index_params)
      if @market_index.save
        redirect_to settings_market_indices_path, notice: "Index created."
      else
        @currencies = Currency.order(:code)
        render :new, status: :unprocessable_entity
      end
    end

    def update
      if @market_index.update(index_params)
        redirect_to settings_market_indices_path, notice: "Index updated."
      else
        @currencies = Currency.order(:code)
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @market_index.destroy!
      redirect_to settings_market_indices_path, notice: "Index removed."
    end

    private

    def set_index
      @market_index = MarketIndex.find(params[:id])
    end

    def index_params
      params.require(:market_index).permit(:name, :code, :description, :currency_id)
    end
  end
end
