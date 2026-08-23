# frozen_string_literal: true

class PricesController < ApplicationController
  def index
    wallet_type = AssetType.find_by(key: "wallet")
    scope = Asset.active.includes(:currency, :category)
    scope = scope.where.not(asset_type_id: wallet_type.id) if wallet_type
    @latest = scope.order(:code).map do |a|
      p = a.asset_prices.where(currency_id: a.currency_id).order(date: :desc).first
      [ a, p ]
    end
    @indices = MarketIndex.includes(:currency).order(:code).map do |i|
      p = i.index_prices.order(date: :desc).first
      [ i, p ]
    end
    @asset_price = AssetPrice.new(date: Date.current)
    if (aid = params[:asset_id].presence)
      asset = Asset.find_by(id: aid)
      if asset
        @asset_price.asset_id = asset.id
        @asset_price.currency_id = asset.currency_id
      end
    end
    @return_to_asset = (params[:return_to] == "asset" || params[:asset_id].present?)
    @assets = Asset.active.order(:code)
    @price_sources = PriceSource.active.order(:position)
    @currencies = Currency.order(:code)
    @price_fetch_status = PriceFetchStatusTracker.status_for(current_user.id)
  end

  def create
    src = PriceSource.find(asset_price_params[:price_source_id])
    ap = AssetPrice.find_or_initialize_by(
      asset_id: asset_price_params[:asset_id],
      currency_id: asset_price_params[:currency_id],
      date: asset_price_params[:date]
    )
    ap.assign_attributes(price: asset_price_params[:price], price_source: src)
    if ap.save
      redirect_to price_success_redirect(ap.asset_id), notice: "Price saved."
    else
      flash.now[:alert] = ap.errors.full_messages.to_sentence
      setup_index_ivars
      render :index, status: :unprocessable_entity
    end
  end

  def fetch
    fetch_date = parse_fetch_date_param

    if PriceFetchStatusTracker.running?(current_user.id)
      message = "A fetch is already running..."
      status = PriceFetchStatusTracker.status_for(current_user.id).merge(message: message)
    else
      PriceFetchStatusTracker.start!(current_user.id)
      broadcast_fetch_controls!(PriceFetchStatusTracker.status_for(current_user.id))

      summary = PriceFetcherService.fetch_all(date: fetch_date) do |progress|
        progress_message = "Fetching prices... #{progress[:current]}/#{progress[:total]} (ok: #{progress[:success]}, failed: #{progress[:failed]}) - #{progress[:asset_code]}"
        PriceFetchStatusTracker.update_running!(current_user.id, message: progress_message)
        broadcast_fetch_controls!(PriceFetchStatusTracker.status_for(current_user.id))
      end

      message = if summary[:failed].positive?
                  "Price fetch finished: #{summary[:success]}/#{summary[:total]} succeeded, #{summary[:failed]} failed."
                else
                  "Price fetch finished: #{summary[:success]} updated."
                end
      PriceFetchStatusTracker.finish!(current_user.id, message: message)
      status = PriceFetchStatusTracker.status_for(current_user.id)
      broadcast_fetch_controls!(status)
    end

    respond_to do |format|
      format.turbo_stream do
        if turbo_fetch_redirect?
          redirect_to fetch_redirect_path(fetch_date), notice: message, status: :see_other
        else
          render turbo_stream: turbo_stream.replace(
            "price_fetch_controls",
            partial: "prices/fetch_controls",
            locals: { status: status }
          )
        end
      end
      format.html { redirect_to fetch_redirect_path(fetch_date), notice: message }
    end
  rescue StandardError => e
    error_message = "Price fetch failed: #{e.message}"
    PriceFetchStatusTracker.finish!(current_user.id, message: error_message)
    broadcast_fetch_controls!(PriceFetchStatusTracker.status_for(current_user.id))
    respond_to do |format|
      format.turbo_stream do
        if turbo_fetch_redirect?
          redirect_to fetch_redirect_path(fetch_date), alert: error_message, status: :see_other
        else
          render turbo_stream: turbo_stream.replace(
            "price_fetch_controls",
            partial: "prices/fetch_controls",
            locals: { status: PriceFetchStatusTracker.status_for(current_user.id) }
          )
        end
      end
      format.html { redirect_to fetch_redirect_path(fetch_date), alert: error_message }
    end
  end

  private

  def parse_fetch_date_param
    raw = params[:date].presence
    return Date.current if raw.blank?

    Date.parse(raw.to_s)
  rescue ArgumentError
    Date.current
  end

  def fetch_redirect_path(fetch_date)
    if params[:return_to].to_s == "asset_performance"
      from_d = performance_redirect_range_date(:from, fetch_date)
      to_d = performance_redirect_range_date(:to, fetch_date)
      from_d, to_d = [ from_d, to_d ].minmax
      performance_assets_path(from: from_d.iso8601, to: to_d.iso8601)
    else
      prices_path
    end
  end

  def performance_redirect_range_date(key, fetch_date)
    raw = params[key]
    return fetch_date if raw.blank?

    Date.parse(raw.to_s)
  rescue ArgumentError
    fetch_date
  end

  def turbo_fetch_redirect?
    params[:return_to].to_s == "asset_performance"
  end

  def broadcast_fetch_controls!(status)
    Turbo::StreamsChannel.broadcast_replace_to(
      "prices_#{current_user.id}",
      target: "price_fetch_controls",
      partial: "prices/fetch_controls",
      locals: { status: status }
    )
  end

  def price_success_redirect(asset_id)
    params[:return_to] == "asset" ? asset_path(asset_id) : prices_path
  end

  def asset_price_params
    params.require(:asset_price).permit(:asset_id, :currency_id, :date, :price, :price_source_id)
  end

  def setup_index_ivars
    wallet_type = AssetType.find_by(key: "wallet")
    scope = Asset.active.includes(:currency, :category)
    scope = scope.where.not(asset_type_id: wallet_type.id) if wallet_type
    @latest = scope.order(:code).map do |a|
      p = a.asset_prices.where(currency_id: a.currency_id).order(date: :desc).first
      [ a, p ]
    end
    @indices = MarketIndex.includes(:currency).order(:code).map do |i|
      p = i.index_prices.order(date: :desc).first
      [ i, p ]
    end
    @asset_price = AssetPrice.new(asset_price_params)
    @return_to_asset = (params[:return_to] == "asset")
    @assets = Asset.active.order(:code)
    @price_sources = PriceSource.active.order(:position)
    @currencies = Currency.order(:code)
  end
end
