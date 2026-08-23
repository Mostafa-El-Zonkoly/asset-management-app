# frozen_string_literal: true

class TransactionsController < ApplicationController
  before_action :load_collections, only: %i[new create edit update]
  before_action :set_transaction, only: %i[show edit update]

  def index
    @q = PortfolioTransaction.includes(:portfolio, :asset, :transaction_type, :currency).ransack(params[:q])
    @pagy, @transactions = pagy(@q.result.order(date: :desc), items: 40)
    @latest_price_by_asset_id = latest_trading_currency_prices(@transactions.map(&:asset_id).uniq)
  end

  def show; end

  def edit; end

  def update
    TransactionAmendService.call!(@transaction, transaction_update_params)
    redirect_to transaction_path(@transaction), notice: "Transaction updated."
  rescue TransactionAmendService::Error => e
    @transaction.reload
    flash.now[:alert] = e.message
    render :edit, status: :unprocessable_entity
  end

  def new
    @transaction = PortfolioTransaction.new(date: Time.current)
    if (aid = params[:asset_id].presence)
      @transaction.asset_id = aid
      asset = Asset.find_by(id: aid)
      if asset
        @transaction.currency_id = asset.currency_id
        @return_to_asset = true
      end
    end
    @transaction.portfolio_id = params[:portfolio_id] if params[:portfolio_id].present?
  end

  def create
    TransactionProcessorService.call!(transaction_processor_params)
    redirect_to transaction_success_redirect, notice: "Transaction recorded."
  rescue TransactionProcessorService::Error => e
    @transaction = PortfolioTransaction.new(transaction_view_params)
    @return_to_asset = (params[:return_to] == "asset")
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  private

  def set_transaction
    @transaction = PortfolioTransaction.includes(:transaction_type, :portfolio, :asset, :currency).find(params[:id])
  end

  def transaction_update_params
    params.require(:portfolio_transaction).permit(
      :portfolio_id, :quantity, :price_per_unit,
      :total_amount, :currency_id, :date, :related_wallet_id, :transfer_to_wallet_id, :notes
    )
  end

  def transaction_success_redirect
    if params[:return_to] == "asset"
      aid = params.dig(:portfolio_transaction, :asset_id).presence
      return asset_path(aid) if aid.present?
    end
    transactions_path
  end

  def load_collections
    @portfolios = Portfolio.order(:name)
    @assets = Asset.active.order(:code)
    @transaction_types = TransactionType.active.order(:position)
    @currencies = Currency.order(:code)
    @wallets = Asset.active.wallets.order(:code)
  end

  def transaction_processor_params
    p = params.require(:portfolio_transaction)
    {
      portfolio_id: p[:portfolio_id].presence,
      asset_id: p[:asset_id],
      transaction_type_id: p[:transaction_type_id],
      quantity: p[:quantity],
      price_per_unit: p[:price_per_unit],
      total_amount: p[:total_amount],
      currency_id: p[:currency_id],
      date: p[:date],
      related_wallet_id: p[:related_wallet_id].presence,
      transfer_to_wallet_id: p[:transfer_to_wallet_id].presence,
      notes: p[:notes],
      exchange_rate_at_transaction: p[:exchange_rate_at_transaction].presence
    }
  end

  def transaction_view_params
    params.require(:portfolio_transaction).permit(
      :portfolio_id, :asset_id, :transaction_type_id, :quantity, :price_per_unit,
      :total_amount, :currency_id, :date, :related_wallet_id, :transfer_to_wallet_id, :notes
    )
  end

  def latest_trading_currency_prices(asset_ids)
    return {} if asset_ids.blank?

    AssetPrice
      .joins(:asset)
      .where(asset_id: asset_ids)
      .where("assets.currency_id = asset_prices.currency_id")
      .order(asset_id: :asc, date: :desc)
      .pluck(:asset_id, :price)
      .each_with_object({}) { |(aid, price), memo| memo[aid] ||= price.to_d }
  end
end
