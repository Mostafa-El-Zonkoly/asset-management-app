# frozen_string_literal: true

# One line in the "list to purify" (تطهير) for a lot in a given period.
# The app produces the list; the amount is entered manually and the money is
# computed outside the app.
class PurificationEntry < ApplicationRecord
  include TenantScoped
  tenant_through :portfolio
  METHODS  = %w[aaoifi sp].freeze
  STATUSES = %w[pending done not_required].freeze

  belongs_to :portfolio
  belongs_to :asset
  belongs_to :asset_lot

  validates :method, inclusion: { in: METHODS }
  validates :status, inclusion: { in: STATUSES }
  validates :quarter, :period_start, :period_end, :quantity, presence: true

  scope :pending,   -> { where(status: "pending") }
  scope :chronological, -> { order(:period_start, :asset_lot_id) }

  def done?
    status == "done"
  end
end
