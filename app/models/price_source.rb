# frozen_string_literal: true

class PriceSource < ApplicationRecord
  include LookupRow

  has_many :asset_prices, dependent: :restrict_with_error
  has_many :index_prices, dependent: :restrict_with_error
  has_many :exchange_rates, dependent: :restrict_with_error
end
