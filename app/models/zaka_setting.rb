# frozen_string_literal: true

# Singleton-style row: nisab reference, suggested rate, payment interval for overdue warnings.
class ZakaSetting < ApplicationRecord
  belongs_to :nisab_asset, class_name: "Asset", optional: true

  validates :rate_percentage,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :payment_interval_days,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 3660 }
  validates :nisab_quantity,
    numericality: { greater_than: 0 },
    allow_nil: true
  validate :nisab_asset_and_quantity_consistency

  def self.record
    first_or_create!
  end

  def nisab_configured?
    nisab_asset_id.present? && nisab_quantity.present? && nisab_quantity.to_d.positive?
  end

  private

  def nisab_asset_and_quantity_consistency
    if nisab_asset_id.present? && (nisab_quantity.blank? || nisab_quantity.to_d <= 0)
      errors.add(:nisab_quantity, "must be greater than 0 when a nisab asset is selected")
    end
    if nisab_quantity.present? && nisab_quantity.to_d.positive? && nisab_asset_id.blank?
      errors.add(:nisab_asset_id, "is required when nisab quantity is set")
    end
  end
end
