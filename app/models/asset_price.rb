# frozen_string_literal: true

class AssetPrice < ApplicationRecord
  belongs_to :asset
  belongs_to :currency
  belongs_to :price_source

  validates :price, :date, presence: true
  validates :asset_id, uniqueness: { scope: [ :currency_id, :date ] }
end
