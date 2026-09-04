# frozen_string_literal: true

class Holding < ApplicationRecord
  include TenantScoped
  tenant_through :portfolio
  belongs_to :portfolio
  belongs_to :asset
  belongs_to :currency

  validates :quantity, numericality: true
  validates :portfolio_id, uniqueness: { scope: :asset_id }
  validate :no_wallet_assets

  before_validation :sync_currency_from_asset

  private

  def sync_currency_from_asset
    self.currency_id = asset.currency_id if asset&.currency_id
  end

  def no_wallet_assets
    return unless asset&.wallet?

    errors.add(:asset_id, "wallets are not held inside a portfolio")
  end
end
