# frozen_string_literal: true

class AddCoreScoring < ActiveRecord::Migration[7.2]
  def change
    add_column :assets, :core_candidate, :boolean, default: false, null: false
    add_column :assets, :entry_score, :decimal, precision: 5, scale: 2
    add_column :assets, :quality_score, :decimal, precision: 5, scale: 2
    add_column :assets, :catalyst_score, :decimal, precision: 5, scale: 2
    add_column :assets, :catalyst_note, :text
    add_column :assets, :sharia_score_override, :decimal, precision: 5, scale: 2
    add_index :assets, :core_candidate

    create_table :core_scoring_settings do |t|
      # Factor weights (any positive scale; total need not be 100 — scores are normalised).
      t.decimal :weight_entry,      precision: 6, scale: 2, null: false, default: "25.0"
      t.decimal :weight_quality,    precision: 6, scale: 2, null: false, default: "20.0"
      t.decimal :weight_catalyst,   precision: 6, scale: 2, null: false, default: "10.0"
      t.decimal :weight_stock,      precision: 6, scale: 2, null: false, default: "15.0"
      t.decimal :weight_sector,     precision: 6, scale: 2, null: false, default: "10.0"
      t.decimal :weight_subsector,  precision: 6, scale: 2, null: false, default: "10.0"
      t.decimal :weight_sharia,     precision: 6, scale: 2, null: false, default: "10.0"

      # Weight-balance bands (percent of the "stocks part"): full score at/below _full, zero at/above _cap.
      t.decimal :stock_full_pct,     precision: 6, scale: 2, null: false, default: "6.0"
      t.decimal :stock_cap_pct,      precision: 6, scale: 2, null: false, default: "14.0"
      t.decimal :sector_full_pct,    precision: 6, scale: 2, null: false, default: "15.0"
      t.decimal :sector_cap_pct,     precision: 6, scale: 2, null: false, default: "25.0"
      t.decimal :subsector_full_pct, precision: 6, scale: 2, null: false, default: "8.0"
      t.decimal :subsector_cap_pct,  precision: 6, scale: 2, null: false, default: "18.0"

      # Sharia mapping from zaka_percentage: at/below _clean => full, at/above _dirty => zero.
      t.decimal :sharia_clean_pct,   precision: 6, scale: 2, null: false, default: "0.0"
      t.decimal :sharia_dirty_pct,   precision: 6, scale: 2, null: false, default: "5.0"

      # Technical "extended" helper (does NOT affect score).
      t.decimal :extended_near_high_pct, precision: 6, scale: 2, null: false, default: "5.0"
      t.decimal :extended_above_ma_pct,  precision: 6, scale: 2, null: false, default: "15.0"
      t.integer :ma_period_days,         null: false, default: 50

      t.timestamps
    end
  end
end
