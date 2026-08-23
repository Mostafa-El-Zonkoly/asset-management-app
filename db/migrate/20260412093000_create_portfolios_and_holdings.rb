# frozen_string_literal: true

class CreatePortfoliosAndHoldings < ActiveRecord::Migration[7.2]
  def change
    create_table :portfolios do |t|
      t.string :name, null: false
      t.text :description
      t.references :base_currency, null: false, foreign_key: { to_table: :currencies }
      t.timestamps
    end

    create_table :portfolio_targets do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :category, null: false, foreign_key: true
      t.decimal :target_percentage, precision: 8, scale: 4
      t.decimal :target_amount, precision: 20, scale: 8
      t.references :target_type, null: false, foreign_key: true
      t.timestamps
    end
    add_index :portfolio_targets, [ :portfolio_id, :category_id ], unique: true

    create_table :holdings do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.decimal :quantity, precision: 20, scale: 8, default: "0", null: false
      t.decimal :average_buy_price, precision: 20, scale: 8
      t.references :currency, null: false, foreign_key: true
      t.timestamps
    end
    add_index :holdings, [ :portfolio_id, :asset_id ], unique: true
  end
end
