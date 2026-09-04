# frozen_string_literal: true

# Singleton-style config for the Core Add ranking: factor weights, weight-balance
# bands, sharia mapping, and technical "extended" helper thresholds.
class CoreScoringSetting < ApplicationRecord
  include TenantScoped
  WEIGHT_FIELDS = %i[
    weight_entry weight_quality weight_catalyst
    weight_stock weight_sector weight_subsector weight_sharia
  ].freeze

  THRESHOLD_FIELDS = %i[
    stock_full_pct stock_cap_pct sector_full_pct sector_cap_pct
    subsector_full_pct subsector_cap_pct sharia_clean_pct sharia_dirty_pct
    extended_near_high_pct extended_above_ma_pct
  ].freeze

  validates(*WEIGHT_FIELDS, numericality: { greater_than_or_equal_to: 0 })
  validates(*THRESHOLD_FIELDS, numericality: { greater_than_or_equal_to: 0 })
  validates :ma_period_days, numericality: { only_integer: true, greater_than: 1, less_than_or_equal_to: 400 }
  validate :bands_ordered

  def self.record
    first_or_create!
  end

  def total_weight
    WEIGHT_FIELDS.sum { |f| public_send(f).to_d }
  end

  private

  # A band's "full" point must be below its "cap" point, else the score is undefined.
  def bands_ordered
    {
      stock: [stock_full_pct, stock_cap_pct],
      sector: [sector_full_pct, sector_cap_pct],
      subsector: [subsector_full_pct, subsector_cap_pct],
      sharia: [sharia_clean_pct, sharia_dirty_pct]
    }.each do |name, (full, cap)|
      next if full.blank? || cap.blank?

      errors.add(:base, "#{name} 'full' threshold must be below its 'cap'") if full.to_d >= cap.to_d
    end
  end
end
