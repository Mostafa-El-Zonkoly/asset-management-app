# frozen_string_literal: true

class IndexPrice < ApplicationRecord
  include TenantScoped
  tenant_through :market_index
  belongs_to :market_index
  belongs_to :price_source

  validates :price, :date, presence: true
  validates :market_index_id, uniqueness: { scope: :date }
end
