# frozen_string_literal: true

class ZakaPayment < ApplicationRecord
  include TenantScoped
  belongs_to :currency

  validates :paid_on, presence: true
  validates :amount, numericality: { greater_than: 0 }
  validates :currency_id, presence: true

  scope :recent_first, -> { order(paid_on: :desc, id: :desc) }

  def self.latest
    recent_first.first
  end
end
