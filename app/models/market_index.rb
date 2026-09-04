# frozen_string_literal: true

class MarketIndex < ApplicationRecord
  include TenantScoped
  belongs_to :currency
  has_many :assets, dependent: :restrict_with_error
  has_many :index_prices, dependent: :destroy

  validates :name, :code, presence: true
  validates :code, uniqueness: { case_sensitive: false }
end
