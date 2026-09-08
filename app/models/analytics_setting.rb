# frozen_string_literal: true

# Per-user analytics config (singleton). Currently the annual risk-free rate used
# in the Sharpe ratio.
class AnalyticsSetting < ApplicationRecord
  include TenantScoped

  validates :risk_free_rate_pct,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  def self.record
    first_or_create!
  end
end
