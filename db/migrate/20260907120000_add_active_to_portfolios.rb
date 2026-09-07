# frozen_string_literal: true

class AddActiveToPortfolios < ActiveRecord::Migration[7.2]
  def change
    add_column :portfolios, :active, :boolean, default: true, null: false
    add_index :portfolios, :active
  end
end
