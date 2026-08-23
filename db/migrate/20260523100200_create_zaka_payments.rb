# frozen_string_literal: true

class CreateZakaPayments < ActiveRecord::Migration[7.2]
  def change
    create_table :zaka_payments do |t|
      t.date :paid_on, null: false
      t.decimal :amount, precision: 20, scale: 8, null: false
      t.references :currency, null: false, foreign_key: true
      t.text :notes

      t.timestamps
    end

    add_index :zaka_payments, %i[paid_on id], order: { paid_on: :desc, id: :desc }
  end
end
