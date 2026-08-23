# frozen_string_literal: true

class Asset < ApplicationRecord
  PRICE_PROVIDERS = %w[hermes azimut].freeze

  belongs_to :category
  belongs_to :asset_type
  belongs_to :currency
  belongs_to :stock_purpose, optional: true
  belongs_to :sector, optional: true
  belongs_to :speciality, optional: true
  belongs_to :fund_type, optional: true
  belongs_to :fund_style, optional: true
  belongs_to :management_style, optional: true
  belongs_to :market_index, optional: true

  has_many :holdings, dependent: :restrict_with_error
  has_many :portfolio_transactions, dependent: :restrict_with_error
  has_many :asset_prices, dependent: :destroy
  has_many :related_wallet_transactions, class_name: "PortfolioTransaction", foreign_key: :related_wallet_id, dependent: :restrict_with_error, inverse_of: :related_wallet
  has_many :transfer_to_transactions, class_name: "PortfolioTransaction", foreign_key: :transfer_to_wallet_id, dependent: :restrict_with_error, inverse_of: :transfer_to_wallet

  validates :name, :code, presence: true
  validates :code, uniqueness: { case_sensitive: false }
  validates :zaka_percentage,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :price_provider, inclusion: { in: PRICE_PROVIDERS }, allow_blank: true
  validates :price_provider_key, presence: { message: "is required when a price provider is set" }, if: -> { price_provider.present? }
  validate :stock_fields_consistency
  validate :fund_fields_consistency
  validate :speciality_matches_sector
  validate :wallet_static_target

  scope :active, -> { where(active: true) }
  scope :wallets, -> { joins(:asset_type).where(asset_types: { key: "wallet" }) }
  scope :direct_stock, -> { joins(:asset_type).where(asset_types: { key: "direct_stock" }) }

  def wallet?
    asset_type&.key == "wallet"
  end

  def direct_stock?
    asset_type&.key == "direct_stock"
  end

  def mutual_fund?
    asset_type&.key == "mutual_fund"
  end

  def to_param
    code
  end

  private

  def stock_fields_consistency
    return unless direct_stock?

    errors.add(:sector_id, "is required for direct stocks") if sector_id.blank?
  end

  def fund_fields_consistency
    return unless mutual_fund?

    errors.add(:fund_type_id, "is required for mutual funds") if fund_type_id.blank?
    errors.add(:management_style_id, "is required for mutual funds") if management_style_id.blank?
    return if fund_type.blank?

    if fund_type.key == "stock_fund"
      errors.add(:fund_style_id, "is required for stock funds") if fund_style_id.blank?
      if fund_style&.key == "index" && market_index_id.blank?
        errors.add(:market_index_id, "is required for index stock funds")
      end
    end
  end

  def speciality_matches_sector
    return if speciality_id.blank? || sector_id.blank?
    return if speciality.sector_id == sector_id

    errors.add(:speciality_id, "must belong to the selected sector")
  end

  def wallet_static_target
    return unless wallet?

    # static_target is optional even for wallets
    true
  end
end
