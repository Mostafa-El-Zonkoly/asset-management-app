# frozen_string_literal: true

class CreateAssets < ActiveRecord::Migration[7.2]
  def change
    create_table :assets do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.references :category, null: false, foreign_key: true
      t.references :asset_type, null: false, foreign_key: true
      t.references :currency, null: false, foreign_key: true

      t.references :stock_purpose, foreign_key: true
      t.references :sector, foreign_key: true
      t.references :speciality, foreign_key: true

      t.references :fund_type, foreign_key: true
      t.references :fund_style, foreign_key: true
      t.references :management_style, foreign_key: true
      t.references :market_index, foreign_key: true

      t.decimal :static_target, precision: 20, scale: 8
      t.text :notes
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :assets, :code, unique: true
  end
end
