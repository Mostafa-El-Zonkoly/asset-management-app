# frozen_string_literal: true

# Per-portfolio external cash movements — money crossing the portfolio boundary.
# Kept SEPARATE from `transactions` (buy/sell/dividend stay internal capital
# recycling) so existing wallet/holdings/P&L behaviour is untouched. These are the
# ONLY flows that count as external capital for contributions/withdrawals and for
# TWR/XIRR; a portfolio-to-portfolio transfer is two linked legs (transfer_out +
# transfer_in) sharing transfer_pair_id, and nets to zero at the Master level.
class CreatePortfolioCashFlows < ActiveRecord::Migration[7.2]
  def change
    create_table :portfolio_cash_flows do |t|
      t.references :user, null: false, foreign_key: true
      t.references :portfolio, null: false, foreign_key: true
      t.references :currency, null: false, foreign_key: true
      t.references :related_wallet, foreign_key: { to_table: :assets } # wallet for contribution/withdrawal
      t.references :counterparty_portfolio, foreign_key: { to_table: :portfolios } # other leg for transfers

      t.string   :kind, null: false # contribution | withdrawal | transfer_in | transfer_out
      t.decimal  :amount, precision: 20, scale: 8, null: false
      t.datetime :occurred_at, null: false
      t.uuid     :transfer_pair_id
      t.text     :notes

      t.timestamps
    end

    add_index :portfolio_cash_flows, [:portfolio_id, :occurred_at]
    add_index :portfolio_cash_flows, :kind
    add_index :portfolio_cash_flows, :transfer_pair_id
  end
end
