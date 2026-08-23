# frozen_string_literal: true

class CreatePricesAndSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :asset_prices do |t|
      t.references :asset, null: false, foreign_key: true
      t.decimal :price, precision: 20, scale: 8, null: false
      t.references :currency, null: false, foreign_key: true
      t.date :date, null: false
      t.references :price_source, null: false, foreign_key: true
      t.timestamps
    end
    add_index :asset_prices, [ :asset_id, :currency_id, :date ], unique: true, name: "index_asset_prices_unique_day"

    create_table :index_prices do |t|
      t.references :market_index, null: false, foreign_key: true
      t.decimal :price, precision: 20, scale: 8, null: false
      t.date :date, null: false
      t.references :price_source, null: false, foreign_key: true
      t.timestamps
    end
    add_index :index_prices, [ :market_index_id, :date ], unique: true

    create_table :portfolio_snapshots do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.decimal :total_value, precision: 20, scale: 8, null: false
      t.references :currency, null: false, foreign_key: true
      t.date :date, null: false
      t.timestamps
    end
    add_index :portfolio_snapshots, [ :portfolio_id, :date ], unique: true
  end
end
