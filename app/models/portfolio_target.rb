# frozen_string_literal: true

class PortfolioTarget < ApplicationRecord
  belongs_to :portfolio
  belongs_to :category
  belongs_to :target_type

  validates :portfolio_id, uniqueness: { scope: :category_id }
  validate :target_value_matches_type

  private

  def target_value_matches_type
    return if target_type.blank?

    case target_type.key
    when "percentage"
      errors.add(:target_percentage, "must be set for percentage targets") if target_percentage.blank?
    when "static_amount"
      errors.add(:target_amount, "must be set for static amount targets") if target_amount.blank?
    end
  end
end
