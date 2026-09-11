# frozen_string_literal: true

# Lightweight point-in-time snapshot saved on report export (spec AL/AM). Stores
# summary metrics + weights only (NOT the whole transaction history), so the app
# can later compare how the book evolved between snapshots.
class CreatePortfolioReportSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :portfolio_report_snapshots do |t|
      t.references :user, null: false, foreign_key: true
      t.datetime :generated_at, null: false
      t.string   :scope, null: false, default: "full"
      t.decimal  :master_nav, precision: 20, scale: 8
      t.jsonb    :payload, null: false, default: {}
      t.timestamps
    end
    add_index :portfolio_report_snapshots, :generated_at
  end
end
