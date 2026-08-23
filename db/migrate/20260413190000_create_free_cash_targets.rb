# frozen_string_literal: true

class CreateFreeCashTargets < ActiveRecord::Migration[7.2]
  def change
    create_table :free_cash_targets do |t|
      t.decimal :target_amount, precision: 20, scale: 8
      t.timestamps
    end
  end
end
