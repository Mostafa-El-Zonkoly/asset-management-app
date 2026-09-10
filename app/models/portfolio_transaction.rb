# frozen_string_literal: true

class PortfolioTransaction < ApplicationRecord
  include TenantScoped
  tenant_through :portfolio, :asset
  self.table_name = "transactions"

  POSITION_ROLES = %w[base temporary].freeze
  SELL_FROMS = %w[temporary_first temporary base specific_lot].freeze
  POSITION_ROLE_LABELS = { "base" => "Base", "temporary" => "Temporary" }.freeze
  SELL_FROM_LABELS = {
    "temporary_first" => "Temporary first", "temporary" => "Temporary",
    "base" => "Base", "specific_lot" => "Specific lot"
  }.freeze

  # Types for which portfolio_id may be changed after posting (holdings / attribution only).
  PORTFOLIO_REASSIGNABLE_TYPE_KEYS = %w[buy sell cash_dividend stock_dividend deduction].freeze

  # Types for which qty/amount/wallet/portfolio edits are supported along with holdings & wallet ledger.
  FINANCIALLY_AMENDABLE_TYPE_KEYS = %w[buy sell cash_dividend stock_dividend deposit withdrawal deduction].freeze

  belongs_to :portfolio, optional: true
  belongs_to :asset
  belongs_to :transaction_type
  belongs_to :currency
  belongs_to :related_wallet, class_name: "Asset", optional: true
  belongs_to :transfer_to_wallet, class_name: "Asset", optional: true

  validates :quantity, :total_amount, :date, presence: true
  validate :portfolio_presence_matches_type
  validates :position_role, inclusion: { in: POSITION_ROLES }, allow_nil: true
  validates :sell_from, inclusion: { in: SELL_FROMS }, allow_nil: true

  before_validation :apply_position_role_defaults

  def buy?
    transaction_type&.key == "buy"
  end

  def sell?
    transaction_type&.key == "sell"
  end

  def position_role_label
    POSITION_ROLE_LABELS[position_role]
  end

  def sell_from_label
    SELL_FROM_LABELS[sell_from]
  end

  def portfolio_reassignable?
    transaction_type && PORTFOLIO_REASSIGNABLE_TYPE_KEYS.include?(transaction_type.key)
  end

  def financially_amendable?
    transaction_type && FINANCIALLY_AMENDABLE_TYPE_KEYS.include?(transaction_type.key)
  end

  def transfer_transaction?
    transaction_type&.key == "transfer"
  end

  def editable_metadata?
    true
  end

  private

  def apply_position_role_defaults
    self.position_role = "base" if buy? && position_role.blank?
    self.sell_from = "temporary_first" if sell? && sell_from.blank?
  end

  def portfolio_presence_matches_type
    return unless transaction_type

    key = transaction_type.key
    wallet_only = %w[deposit withdrawal transfer].include?(key)
    if wallet_only && portfolio_id.present?
      errors.add(:portfolio_id, "must be blank for wallet-only transactions")
    elsif !wallet_only && portfolio_id.blank?
      errors.add(:portfolio_id, "is required")
    end
  end
end
