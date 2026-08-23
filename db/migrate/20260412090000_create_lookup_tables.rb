# frozen_string_literal: true

class CreateLookupTables < ActiveRecord::Migration[7.2]
  def change
    create_table :asset_types do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :asset_types, :key, unique: true

    create_table :stock_purposes do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :stock_purposes, :key, unique: true

    create_table :sectors do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :sectors, :key, unique: true

    create_table :specialities do |t|
      t.references :sector, null: false, foreign_key: true
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :specialities, :key, unique: true

    create_table :fund_types do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :fund_types, :key, unique: true

    create_table :fund_styles do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :fund_styles, :key, unique: true

    create_table :management_styles do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :management_styles, :key, unique: true

    create_table :category_types do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :category_types, :key, unique: true

    create_table :transaction_types do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :transaction_types, :key, unique: true

    create_table :price_sources do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :price_sources, :key, unique: true

    create_table :target_types do |t|
      t.string :key, null: false
      t.string :label, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :target_types, :key, unique: true
  end
end
