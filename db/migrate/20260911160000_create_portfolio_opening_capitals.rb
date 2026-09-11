# frozen_string_literal: true

# User-entered migration baseline per portfolio (spec #AO "Legacy Opening Capital").
# Historical BUYs are NOT contributions, so each portfolio's opening external
# capital + opening cash are set explicitly as of migration_on. From that date
# forward, explicit contributions/withdrawals/transfers and post-migration
# transaction cash effects drive the cash balance; before it, holdings + opening
# cash represent the position. Nothing in transaction history is rewritten.
class CreatePortfolioOpeningCapitals < ActiveRecord::Migration[7.2]
  def change
    create_table :portfolio_opening_capitals do |t|
      t.references :user, null: false, foreign_key: true
      t.references :portfolio, null: false, foreign_key: true
      t.references :currency, foreign_key: true

      t.decimal :opening_capital, precision: 20, scale: 8, null: false, default: "0.0"
      t.decimal :opening_cash,    precision: 20, scale: 8, null: false, default: "0.0"
      t.date    :migration_on, null: false
      t.text    :notes

      t.timestamps
    end

    add_index :portfolio_opening_capitals, [:portfolio_id], unique: true, name: "index_opening_capitals_on_portfolio"
  end
end
