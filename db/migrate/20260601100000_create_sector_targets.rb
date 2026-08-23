# frozen_string_literal: true

class CreateSectorTargets < ActiveRecord::Migration[7.2]
  def change
    create_table :sector_targets do |t|
      t.references :sector, null: false, foreign_key: true
      t.decimal :target_percentage, precision: 8, scale: 4, null: false

      t.timestamps
    end

  end
end
