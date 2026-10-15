# frozen_string_literal: true

class Portfolio < ApplicationRecord
  include TenantScoped
  belongs_to :user

  has_many :holdings, dependent: :destroy
  has_many :portfolio_targets, dependent: :destroy
  has_many :portfolio_management_style_targets, dependent: :destroy
  has_many :portfolio_transactions, dependent: :restrict_with_error
  has_many :portfolio_snapshots, dependent: :destroy
  has_many :asset_lots, dependent: :destroy
  has_many :purification_entries, dependent: :destroy
  has_many :portfolio_cash_flows, dependent: :destroy
  has_one  :opening_capital, class_name: "PortfolioOpeningCapital", dependent: :destroy

  belongs_to :whole_target_type, class_name: "TargetType", optional: true
  belongs_to :benchmark_market_index, class_name: "MarketIndex", optional: true
  # Optional: the wallet that holds this portfolio's investment liquidity. When set, the
  # portfolio's overall value (Wealth Return) = holdings + this wallet's balance.
  belongs_to :liquidity_wallet, class_name: "Asset", optional: true

  # How this portfolio's Sharia purification (تطهير) list is segmented:
  #   aaoifi -> split by calendar quarter, day-weighted
  #   sp     -> one entry per lot for its whole holding period
  enum :purification_method, { aaoifi: "aaoifi", sp: "sp" }, default: "aaoifi"

  scope :active, -> { where(active: true) }
  scope :disabled, -> { where(active: false) }

  validates :name, presence: true
  validates :key, uniqueness: { allow_blank: true, scope: :user_id },
                  format: { with: /\A[a-z0-9_-]+\z/, message: "only lowercase letters, numbers, hyphens, and underscores", allow_blank: true }
  validate :whole_portfolio_target_matches_type
  validate :liquidity_wallet_is_an_unshared_wallet

  before_validation :clear_whole_portfolio_target_values_without_type

  private

  def liquidity_wallet_is_an_unshared_wallet
    return if liquidity_wallet_id.blank?

    errors.add(:liquidity_wallet_id, "must be a wallet asset") unless liquidity_wallet&.wallet?
    other = Portfolio.where(liquidity_wallet_id: liquidity_wallet_id).where.not(id: id)
    errors.add(:liquidity_wallet_id, "is already the liquidity wallet of #{other.first.name}") if other.exists?
  end

  def clear_whole_portfolio_target_values_without_type
    return if whole_target_type_id.present?

    self.whole_target_percentage = nil
    self.whole_target_amount = nil
  end

  def whole_portfolio_target_matches_type
    return if whole_target_type_id.blank?

    case whole_target_type.key
    when "percentage"
      errors.add(:whole_target_percentage, "must be set for a percentage target") if whole_target_percentage.blank?
    when "static_amount"
      errors.add(:whole_target_amount, "must be set for a static amount target") if whole_target_amount.blank?
    else
      errors.add(:whole_target_type_id, "is not supported for whole-portfolio targets")
    end
  end
end
