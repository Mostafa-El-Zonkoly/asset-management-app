# frozen_string_literal: true

class PortfolioSnapshot < ApplicationRecord
  belongs_to :portfolio
  belongs_to :currency

  validates :total_value, :date, presence: true
  validates :portfolio_id, uniqueness: { scope: :date }
end
