# frozen_string_literal: true

class CreateLotTrackingAndPurification < ActiveRecord::Migration[7.2]
  def change
    add_column :portfolios, :purification_method, :string,
      default: "aaoifi", null: false

    create_table :asset_lots do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.references :currency, null: false, foreign_key: true
      t.references :buy_transaction, null: false,
        foreign_key: { to_table: :transactions }
      t.date :opened_on, null: false
      t.decimal :buy_price_per_unit, precision: 20, scale: 8
      t.decimal :original_quantity, precision: 20, scale: 8, null: false
      t.decimal :remaining_quantity, precision: 20, scale: 8, null: false
      t.timestamps
    end
    add_index :asset_lots, :buy_transaction_id, unique: true
    add_index :asset_lots, %i[portfolio_id asset_id opened_on]

    create_table :lot_closures do |t|
      t.references :asset_lot, null: false, foreign_key: true
      t.references :sell_transaction, null: false,
        foreign_key: { to_table: :transactions }
      t.decimal :quantity, precision: 20, scale: 8, null: false
      t.date :opened_on, null: false
      t.date :closed_on, null: false
      t.decimal :buy_price_per_unit, precision: 20, scale: 8
      t.decimal :sell_price_per_unit, precision: 20, scale: 8
      t.decimal :realised_gain, precision: 20, scale: 8
      t.timestamps
    end
    add_index :lot_closures, %i[asset_lot_id sell_transaction_id], unique: true

    create_table :purification_entries do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.references :asset_lot, null: false, foreign_key: true
      t.string :method, null: false            # aaoifi | sp
      t.string :quarter, null: false           # "2026-Q1" ; "ALL" for sp
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.decimal :quantity, precision: 20, scale: 8, null: false
      t.integer :days, null: false, default: 0
      t.decimal :share_days, precision: 24, scale: 4, null: false, default: "0.0"
      t.string :status, null: false, default: "pending"  # pending|done|not_required
      t.decimal :amount, precision: 20, scale: 8
      t.date :done_on
      t.text :notes
      t.timestamps
    end
    add_index :purification_entries, %i[asset_lot_id quarter], unique: true
  end
end
