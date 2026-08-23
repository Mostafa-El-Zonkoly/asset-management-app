# frozen_string_literal: true

module Settings
  class CurrenciesController < ApplicationController
    before_action :set_currency, only: %i[edit update destroy set_base]

    def index
      @currencies = Currency.order(:code)
    end

    def new
      @currency = Currency.new
    end

    def edit
    end

    def create
      @currency = Currency.new(currency_params)
      if @currency.save
        redirect_to settings_currencies_path, notice: "Currency created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def update
      if @currency.update(currency_params)
        redirect_to settings_currencies_path, notice: "Currency updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @currency.destroy!
      redirect_to settings_currencies_path, notice: "Currency removed."
    end

    def set_base
      Currency.transaction do
        Currency.update_all(is_base: false)
        @currency.update!(is_base: true)
      end
      redirect_to settings_currencies_path, notice: "Base currency updated."
    end

    private

    def set_currency
      @currency = Currency.find(params[:id])
    end

    def currency_params
      params.require(:currency).permit(:code, :name, :symbol, :is_base)
    end
  end
end
