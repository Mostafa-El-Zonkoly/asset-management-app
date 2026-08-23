# frozen_string_literal: true

class AddZakaPercentageToAssets < ActiveRecord::Migration[7.2]
  def change
    add_column :assets, :zaka_percentage, :decimal, precision: 8, scale: 4, null: false, default: 0
  end
end
