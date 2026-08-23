# frozen_string_literal: true

class CreateCurrenciesAndCategories < ActiveRecord::Migration[7.2]
  def change
    create_table :currencies do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :symbol, null: false
      t.boolean :is_base, default: false, null: false
      t.timestamps
    end
    add_index :currencies, :code, unique: true
    add_index :currencies, :is_base, where: "is_base = true", unique: true, name: "index_currencies_one_base"

    create_table :categories do |t|
      t.string :name, null: false
      t.references :category_type, null: false, foreign_key: true
      t.text :description
      t.timestamps
    end

    create_table :market_indices do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.text :description
      t.references :currency, null: false, foreign_key: true
      t.timestamps
    end
    add_index :market_indices, :code, unique: true
  end
end
