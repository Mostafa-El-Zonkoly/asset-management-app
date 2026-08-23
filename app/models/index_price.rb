# frozen_string_literal: true

class IndexPrice < ApplicationRecord
  belongs_to :market_index
  belongs_to :price_source

  validates :price, :date, presence: true
  validates :market_index_id, uniqueness: { scope: :date }
end
