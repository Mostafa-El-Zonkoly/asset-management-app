# frozen_string_literal: true

# Manual entry of an index closing level, mirroring how PricesController#create
# lets you type an asset price. Idempotent per [market_index_id, date] (upsert),
# so re-entering a date corrects the level instead of duplicating it.
class IndexPricesController < ApplicationController
  def create
    market_index = MarketIndex.find(index_price_params[:market_index_id])
    source = PriceSource.find(index_price_params[:price_source_id])

    ip = IndexPrice.find_or_initialize_by(
      market_index_id: market_index.id,
      date: index_price_params[:date]
    )
    ip.assign_attributes(price: index_price_params[:price], price_source: source)

    if ip.save
      redirect_to prices_path, notice: "Index price saved for #{market_index.code}."
    else
      redirect_to prices_path, alert: ip.errors.full_messages.to_sentence.presence || "Could not save index price."
    end
  end

  private

  def index_price_params
    params.require(:index_price).permit(:market_index_id, :date, :price, :price_source_id)
  end
end
