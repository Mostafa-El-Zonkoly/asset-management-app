# frozen_string_literal: true

class CreateAssetEstimates < ActiveRecord::Migration[7.2]
  def change
    create_table :asset_estimates do |t|
      t.references :user, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.references :currency, null: false, foreign_key: true

      t.string  :source_name, null: false
      # Independence key: two source_names sharing a source_family are the SAME
      # underlying dataset (e.g. one analyst consensus republished on two sites)
      # and must not be counted as independent confirmations. Blank => the row is
      # its own independent family (keyed by source_name at read time).
      t.string  :source_family

      t.string  :estimate_type, null: false, default: "fundamental" # fundamental|analyst_consensus|technical|internal_model|other
      # Distinguishes a pure data provider from research/recommendation (spec #10):
      # a "data" row never contributes a target to aggregates even if one is present.
      t.string  :data_role, null: false, default: "recommendation"  # data|research|recommendation

      t.string  :horizon_type, null: false, default: "twelve_month" # short_term|medium_term|twelve_month|long_term|custom
      t.integer :horizon_days

      t.date    :estimate_date, null: false

      t.decimal :target_price, precision: 20, scale: 8
      t.decimal :target_min,   precision: 20, scale: 8
      t.decimal :target_max,   precision: 20, scale: 8

      t.decimal :confidence_score, precision: 5, scale: 4 # 0..1, optional
      t.string  :analyst_name
      t.text    :notes
      t.string  :reference_url

      # Manually flag the preferred representative for a source_family (tie-break).
      t.boolean :preferred, null: false, default: false
      t.boolean :active,    null: false, default: true

      t.timestamps
    end

    add_index :asset_estimates, [:asset_id, :estimate_type]
    add_index :asset_estimates, [:asset_id, :active]
    add_index :asset_estimates, :source_family
    add_index :asset_estimates, :estimate_date
  end
end
