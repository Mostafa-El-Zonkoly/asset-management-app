# frozen_string_literal: true

# Optional per-portfolio liquidity wallet: the wallet that holds the portfolio's cash.
# Used to measure overall value (holdings + wallet balance) for Wealth Return.
class AddLiquidityWalletToPortfolios < ActiveRecord::Migration[7.2]
  def change
    add_reference :portfolios, :liquidity_wallet, foreign_key: { to_table: :assets }, null: true, index: true
  end
end
