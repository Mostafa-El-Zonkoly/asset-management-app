# frozen_string_literal: true

class ChangeFreeCashTargetsToTargetPercentage < ActiveRecord::Migration[7.2]
  def change
    remove_column :free_cash_targets, :target_amount, :decimal, precision: 20, scale: 8
    add_column :free_cash_targets, :target_percentage, :decimal, precision: 8, scale: 4
  end
end
