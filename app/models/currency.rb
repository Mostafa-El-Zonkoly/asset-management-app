# frozen_string_literal: true

class Currency < ApplicationRecord
  include TenantScoped
  has_many :market_indices, dependent: :restrict_with_error
  has_many :assets, dependent: :restrict_with_error
  has_many :holdings, dependent: :restrict_with_error
  has_many :exchange_rates_as_quote, class_name: "ExchangeRate", foreign_key: :currency_id, dependent: :destroy
  has_many :exchange_rates_as_base, class_name: "ExchangeRate", foreign_key: :base_currency_id, dependent: :destroy

  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :name, :symbol, presence: true
  validate :only_one_base_currency

  scope :base, -> { where(is_base: true) }

  # Single reporting currency for aggregating multi-currency portfolios (exchange rates vs this currency).
  def self.reporting_currency_id
    base.pick(:id)
  end

  private

  def only_one_base_currency
    return unless is_base?

    other = Currency.base.where.not(id: id).exists?
    errors.add(:is_base, "only one base currency allowed") if other
  end
end
