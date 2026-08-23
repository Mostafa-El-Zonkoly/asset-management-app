# frozen_string_literal: true

class CreatePortfolioManagementStyleTargets < ActiveRecord::Migration[7.2]
  def change
    create_table :portfolio_management_style_targets do |t|
      t.references :portfolio, null: false, foreign_key: true
      t.references :management_style, null: false, foreign_key: true
      t.decimal :target_percentage, precision: 8, scale: 4
      t.decimal :target_amount, precision: 20, scale: 8
      t.references :target_type, null: false, foreign_key: true
      t.timestamps
    end
    add_index :portfolio_management_style_targets, [ :portfolio_id, :management_style_id ], unique: true, name: "idx_pmst_on_portfolio_and_style"
  end
end
