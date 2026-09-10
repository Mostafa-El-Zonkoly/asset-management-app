# frozen_string_literal: true

class AddBenchmarkToPortfolios < ActiveRecord::Migration[7.2]
  def change
    add_reference :portfolios, :benchmark_market_index, foreign_key: { to_table: :market_indices }, null: true
  end
end
