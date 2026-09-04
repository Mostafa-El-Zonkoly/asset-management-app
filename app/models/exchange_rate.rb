# frozen_string_literal: true

class ExchangeRate < ApplicationRecord
  include TenantScoped
  tenant_through :currency
  belongs_to :currency
  belongs_to :base_currency, class_name: "Currency"
  belongs_to :price_source

  validates :rate, :date, presence: true
  validates :currency_id, uniqueness: { scope: [ :base_currency_id, :date ] }
end
