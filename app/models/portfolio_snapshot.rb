# frozen_string_literal: true

class PortfolioSnapshot < ApplicationRecord
  include TenantScoped
  tenant_through :portfolio
  belongs_to :portfolio
  belongs_to :currency

  validates :total_value, :date, presence: true
  validates :portfolio_id, uniqueness: { scope: :date }
end
