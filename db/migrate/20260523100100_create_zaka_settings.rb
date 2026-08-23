# frozen_string_literal: true

class CreateZakaSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :zaka_settings do |t|
      t.references :nisab_asset, foreign_key: { to_table: :assets }
      t.decimal :nisab_quantity, precision: 20, scale: 8
      t.decimal :rate_percentage, precision: 8, scale: 4, null: false, default: 2.5
      t.integer :payment_interval_days, null: false, default: 354

      t.timestamps
    end
  end
end
