# frozen_string_literal: true

# Add Contribution / Withdraw / Transfer cash. One form: pick From and To
# endpoints (wallet or portfolio); CashTransferService classifies and creates the
# linked PortfolioCashFlow record(s).
class CashMovesController < ApplicationController
  def index
    @flows = PortfolioCashFlow.includes(:portfolio, :currency, :related_wallet, :counterparty_portfolio)
                              .chronological.reverse_order.limit(100)
    @portfolios = current_user.portfolios.order(:name)
  end

  def new
    load_endpoints
    @preset = params[:kind] # optional: contribution/withdrawal/transfer
  end

  def create
    from = parse_endpoint(params[:from])
    to = parse_endpoint(params[:to])
    CashTransferService.call(
      from: from, to: to,
      amount: params[:amount],
      currency_id: params[:currency_id].presence || Currency.reporting_currency_id,
      occurred_at: parse_time(params[:occurred_at]),
      notes: params[:notes].presence
    )
    redirect_to cash_moves_path, notice: "Cash move recorded."
  rescue CashTransferService::Error, ActiveRecord::RecordInvalid => e
    load_endpoints
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  private

  def load_endpoints
    @wallets = Asset.active.wallets.order(:code)
    @portfolios = current_user.portfolios.order(:name)
    @currencies = Currency.order(:code)
  end

  # "wallet:12" / "portfolio:3" => { type:, id: }
  def parse_endpoint(raw)
    type, id = raw.to_s.split(":", 2)
    { type: type, id: id.to_i }
  end

  def parse_time(raw)
    return Time.current if raw.blank?

    Time.zone.parse(raw.to_s) || Time.current
  rescue ArgumentError
    Time.current
  end
end
