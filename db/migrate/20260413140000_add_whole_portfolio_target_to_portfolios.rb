# frozen_string_literal: true

class AddWholePortfolioTargetToPortfolios < ActiveRecord::Migration[7.2]
  def change
    add_reference :portfolios, :whole_target_type, foreign_key: { to_table: :target_types }, null: true
    add_column :portfolios, :whole_target_percentage, :decimal, precision: 8, scale: 4
    add_column :portfolios, :whole_target_amount, :decimal, precision: 20, scale: 8
  end
end
