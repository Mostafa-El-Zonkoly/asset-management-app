# frozen_string_literal: true

class CreateAnalyticsSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :analytics_settings do |t|
      t.decimal :risk_free_rate_pct, precision: 8, scale: 4, null: false, default: "0.0"
      t.references :user, foreign_key: true, index: true, null: true
      t.timestamps
    end
  end
end
