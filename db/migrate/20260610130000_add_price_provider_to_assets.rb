# frozen_string_literal: true

class AddPriceProviderToAssets < ActiveRecord::Migration[7.2]
  def change
    add_column :assets, :price_provider, :string
    add_column :assets, :price_provider_key, :string
    add_column :assets, :price_provider_link, :string

    add_index :assets, :price_provider
  end
end
