# frozen_string_literal: true

# Singleton-style row: global target for wallet cash as % of total wealth (reporting currency).
# Wealth = included portfolio investments + all wallet balances (same denominator as "% combined").
class FreeCashTarget < ApplicationRecord
  validates :target_percentage,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 },
    allow_nil: true

  before_validation :normalize_blank_target

  def self.record
    first_or_create!
  end

  private

  def normalize_blank_target
    self.target_percentage = nil if target_percentage.blank?
  end
end
