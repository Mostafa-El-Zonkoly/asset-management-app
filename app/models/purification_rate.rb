# frozen_string_literal: true

# The two purification inputs for an asset in a calendar quarter (the
# "Totals & Purification" tab of the reference spreadsheet):
#   aaoifi_per_day  purification per SHARE per DAY held (AAOIFI method)
#   sp_percentage   percent of realised profit to purify (S&P method), e.g. 4.25
class PurificationRate < ApplicationRecord
  include TenantScoped
  tenant_through :asset

  belongs_to :asset

  validates :quarter, format: { with: LotLedger::Purification::QUARTER_LABEL }
  validates :quarter, uniqueness: { scope: :asset_id }
  validates :aaoifi_per_day, numericality: { greater_than_or_equal_to: 0 }
  validates :sp_percentage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  scope :for_quarter, ->(quarter) { where(quarter: quarter) }
end
