# frozen_string_literal: true

# Purification redesign.
#
# purification_entries: one row per (lot, quarter, sale). Mirrors one row of the
# reference spreadsheet — a parcel of shares held in a quarter, either CLOSED by
# a sale (sell_transaction_id set) or still ONGOING (sell_transaction_id NULL,
# carried into the next quarter). Each row carries two independent purification
# amounts, each with its own paid flag:
#   * AAOIFI: quantity x days x per-day rate (every quarter the parcel is held)
#   * S&P:    profit x percentage (only on the closing row, only if profit > 0)
#
# purification_rates: the two per-asset, per-quarter inputs (AAOIFI per share
# per day, S&P percentage) — the "Totals & Purification" tab of the spreadsheet.
#
# Requires DeleteAllPurificationEntries to have run (the table must be empty).
class RestructurePurificationEntriesAndAddRates < ActiveRecord::Migration[7.2]
  def up
    remove_index :purification_entries, column: %i[asset_lot_id quarter], unique: true
    remove_column :purification_entries, :method
    remove_column :purification_entries, :status
    remove_column :purification_entries, :amount
    remove_column :purification_entries, :done_on
    remove_column :purification_entries, :share_days

    add_reference :purification_entries, :sell_transaction, null: true,
      foreign_key: { to_table: :transactions, on_delete: :cascade }
    add_column :purification_entries, :buy_price_per_unit,  :decimal, precision: 20, scale: 8
    add_column :purification_entries, :sell_price_per_unit, :decimal, precision: 20, scale: 8
    add_column :purification_entries, :aaoifi_rate,   :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :purification_entries, :aaoifi_amount, :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :purification_entries, :sp_rate,       :decimal, precision: 10, scale: 6, null: false, default: 0
    add_column :purification_entries, :sp_amount,     :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :purification_entries, :aaoifi_paid,    :boolean, null: false, default: false
    add_column :purification_entries, :aaoifi_paid_on, :date
    add_column :purification_entries, :sp_paid,        :boolean, null: false, default: false
    add_column :purification_entries, :sp_paid_on,     :date

    # One ongoing row per (lot, quarter); one closed row per (lot, quarter, sale).
    # Two partial indexes because NULLs are distinct in a plain unique index.
    add_index :purification_entries, %i[asset_lot_id quarter], unique: true,
      where: "sell_transaction_id IS NULL", name: "idx_purification_entries_open_unique"
    add_index :purification_entries, %i[asset_lot_id quarter sell_transaction_id], unique: true,
      where: "sell_transaction_id IS NOT NULL", name: "idx_purification_entries_closed_unique"
    add_index :purification_entries, :quarter

    create_table :purification_rates do |t|
      t.references :user, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.string  :quarter, null: false                                            # "2026-Q3"
      t.decimal :aaoifi_per_day, precision: 20, scale: 8, null: false, default: 0 # per share, per day
      t.decimal :sp_percentage,  precision: 10, scale: 6, null: false, default: 0 # percent of profit, e.g. 4.25
      t.timestamps
    end
    add_index :purification_rates, %i[asset_id quarter], unique: true
  end

  def down
    # New-shape rows (closed + ongoing per lot/quarter) can't satisfy the old
    # unique(asset_lot_id, quarter) index, and the old columns have nothing to
    # be filled from. Regenerate with `bin/rails lot_ledger:purify` after rolling forward again.
    execute "DELETE FROM purification_entries"

    drop_table :purification_rates

    remove_index :purification_entries, name: "idx_purification_entries_open_unique"
    remove_index :purification_entries, name: "idx_purification_entries_closed_unique"
    remove_index :purification_entries, :quarter
    remove_column :purification_entries, :sp_paid_on
    remove_column :purification_entries, :sp_paid
    remove_column :purification_entries, :aaoifi_paid_on
    remove_column :purification_entries, :aaoifi_paid
    remove_column :purification_entries, :sp_amount
    remove_column :purification_entries, :sp_rate
    remove_column :purification_entries, :aaoifi_amount
    remove_column :purification_entries, :aaoifi_rate
    remove_column :purification_entries, :sell_price_per_unit
    remove_column :purification_entries, :buy_price_per_unit
    remove_reference :purification_entries, :sell_transaction, foreign_key: { to_table: :transactions }

    add_column :purification_entries, :share_days, :decimal, precision: 24, scale: 4, null: false, default: "0.0"
    add_column :purification_entries, :done_on, :date
    add_column :purification_entries, :amount, :decimal, precision: 20, scale: 8
    add_column :purification_entries, :status, :string, null: false, default: "pending"
    add_column :purification_entries, :method, :string, null: false, default: "aaoifi"
    add_index :purification_entries, %i[asset_lot_id quarter], unique: true
  end
end
