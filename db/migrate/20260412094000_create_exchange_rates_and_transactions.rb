# frozen_string_literal: true

class CreateExchangeRatesAndTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :exchange_rates do |t|
      t.references :currency, null: false, foreign_key: true
      t.references :base_currency, null: false, foreign_key: { to_table: :currencies }
      t.decimal :rate, precision: 20, scale: 8, null: false
      t.date :date, null: false
      t.references :price_source, null: false, foreign_key: true
      t.timestamps
    end
    add_index :exchange_rates, [ :currency_id, :base_currency_id, :date ], unique: true, name: "index_exchange_rates_unique_pair_date"

    create_table :transactions do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.references :transaction_type, null: false, foreign_key: true
      t.decimal :quantity, precision: 20, scale: 8, default: "0", null: false
      t.decimal :price_per_unit, precision: 20, scale: 8
      t.decimal :total_amount, precision: 20, scale: 8, null: false
      t.references :currency, null: false, foreign_key: true
      t.datetime :date, null: false
      t.references :related_wallet, foreign_key: { to_table: :assets }
      t.references :transfer_to_wallet, foreign_key: { to_table: :assets }
      t.decimal :realised_gain, precision: 20, scale: 8
      t.text :notes
      t.uuid :transfer_pair_id
      t.timestamps
    end
    add_index :transactions, :transfer_pair_id
    add_index :transactions, [ :portfolio_id, :date ]
  end
end
