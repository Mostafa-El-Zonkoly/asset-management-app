# frozen_string_literal: true

class AddKeyToPortfolios < ActiveRecord::Migration[7.2]
  def change
    add_column :portfolios, :key, :string
  end
end
