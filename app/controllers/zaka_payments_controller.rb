# frozen_string_literal: true

class ZakaPaymentsController < ApplicationController
  before_action :set_payment, only: %i[edit update destroy]

  def index
    @payments = ZakaPayment.includes(:currency).recent_first
  end

  def new
    @payment = ZakaPayment.new(
      paid_on: Date.current,
      currency: Currency.base.first
    )
    @currencies = Currency.order(:code)
  end

  def create
    @payment = ZakaPayment.new(payment_params)
    if @payment.save
      redirect_to zaka_payments_path, notice: "Zakaa payment recorded."
    else
      @currencies = Currency.order(:code)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @currencies = Currency.order(:code)
  end

  def update
    if @payment.update(payment_params)
      redirect_to zaka_payments_path, notice: "Zakaa payment updated."
    else
      @currencies = Currency.order(:code)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @payment.destroy!
    redirect_to zaka_payments_path, notice: "Zakaa payment removed."
  end

  private

  def set_payment
    @payment = ZakaPayment.find(params[:id])
  end

  def payment_params
    params.require(:zaka_payment).permit(:paid_on, :amount, :currency_id, :notes)
  end
end
