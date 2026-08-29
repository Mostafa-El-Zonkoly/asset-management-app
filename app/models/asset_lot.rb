# frozen_string_literal: true

# A FIFO parcel opened by a single BUY (or stock_dividend) transaction.
# Its remaining_quantity is decremented as later sells consume it via
# LotClosures. remaining_quantity == 0 means the lot is fully closed.
class AssetLot < ApplicationRecord
  belongs_to :portfolio
  belongs_to :asset
  belongs_to :currency
  belongs_to :buy_transaction, class_name: "PortfolioTransaction"

  has_many :lot_closures, dependent: :destroy
  has_many :purification_entries, dependent: :destroy

  validates :opened_on, :original_quantity, :remaining_quantity, presence: true

  scope :open,   -> { where("remaining_quantity > 0") }
  scope :closed, -> { where("remaining_quantity <= 0") }
  scope :chronological, -> { order(:opened_on, :buy_transaction_id) }

  def open?
    remaining_quantity.to_d.positive?
  end

  def closed?
    !open?
  end
end
