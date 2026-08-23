# frozen_string_literal: true

class AddIncludeInCombinedPercentToPortfolios < ActiveRecord::Migration[7.2]
  def change
    add_column :portfolios, :include_in_combined_percent, :boolean, default: true, null: false
  end
end
