# frozen_string_literal: true

# The migration baseline for a portfolio: opening external capital, opening cash,
# and the date from which explicit cash-flow accounting takes over. One per
# portfolio. Absent => the portfolio has not been migrated yet (cash-based metrics
# read as N/A until it is set).
class PortfolioOpeningCapital < ApplicationRecord
  include TenantScoped
  tenant_through :portfolio

  belongs_to :portfolio
  belongs_to :currency, optional: true

  validates :portfolio_id, uniqueness: { scope: :user_id }
  validates :opening_capital, :opening_cash,
            numericality: { greater_than_or_equal_to: 0 }
  validates :migration_on, presence: true
end
