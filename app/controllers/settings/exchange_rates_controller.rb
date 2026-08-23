# frozen_string_literal: true

module Settings
  class ExchangeRatesController < ApplicationController
    def index
      @rates = ExchangeRate.includes(:currency, :base_currency, :price_source).order(date: :desc, currency_id: :asc).limit(200)
      @rate = ExchangeRate.new(date: Date.current)
      @currencies = Currency.order(:code)
      @price_sources = PriceSource.active.order(:position)
    end

    def create
      @rate = ExchangeRate.new(rate_params)
      if @rate.save
        redirect_to settings_exchange_rates_path, notice: "Rate saved."
      else
        @rates = ExchangeRate.includes(:currency, :base_currency, :price_source).order(date: :desc).limit(200)
        @currencies = Currency.order(:code)
        @price_sources = PriceSource.active.order(:position)
        flash.now[:alert] = @rate.errors.full_messages.to_sentence
        render :index, status: :unprocessable_entity
      end
    end

    def fetch
      ExchangeRateFetchJob.perform_later(current_user.id)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "exchange_rate_fetch_status",
            partial: "settings/exchange_rates/fetch_status",
            locals: { message: "Fetching exchange rates…" }
          )
        end
        format.html { redirect_to settings_exchange_rates_path, notice: "Exchange rate fetch started." }
      end
    end

    private

    def rate_params
      params.require(:exchange_rate).permit(:currency_id, :base_currency_id, :rate, :date, :price_source_id)
    end
  end
end
