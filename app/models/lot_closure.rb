# frozen_string_literal: true

# One matched slice: a sell consuming `quantity` units of a specific lot.
# This is a COMPLETED operation, carrying its FIFO realized gain.
class LotClosure < ApplicationRecord
  include TenantScoped
  tenant_through :asset_lot
  belongs_to :asset_lot
  belongs_to :sell_transaction, class_name: "PortfolioTransaction"

  validates :quantity, :opened_on, :closed_on, presence: true

  scope :chronological, -> { order(:closed_on, :id) }
end
