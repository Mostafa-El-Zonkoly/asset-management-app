# frozen_string_literal: true

class Portfolio < ApplicationRecord
  belongs_to :user

  has_many :holdings, dependent: :destroy
  has_many :portfolio_targets, dependent: :destroy
  has_many :portfolio_management_style_targets, dependent: :destroy
  has_many :portfolio_transactions, dependent: :restrict_with_error
  has_many :portfolio_snapshots, dependent: :destroy
  has_many :asset_lots, dependent: :destroy
  has_many :purification_entries, dependent: :destroy

  belongs_to :whole_target_type, class_name: "TargetType", optional: true

  # How this portfolio's Sharia purification (تطهير) list is segmented:
  #   aaoifi -> split by calendar quarter, day-weighted
  #   sp     -> one entry per lot for its whole holding period
  enum :purification_method, { aaoifi: "aaoifi", sp: "sp" }, default: "aaoifi"

  validates :name, presence: true
  validates :key, uniqueness: { allow_blank: true },
                  format: { with: /\A[a-z0-9_-]+\z/, message: "only lowercase letters, numbers, hyphens, and underscores", allow_blank: true }
  validate :whole_portfolio_target_matches_type

  before_validation :clear_whole_portfolio_target_values_without_type

  private

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
