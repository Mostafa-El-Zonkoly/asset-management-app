# frozen_string_literal: true

class WalletsStandaloneAndPortfolioCurrencies < ActiveRecord::Migration[7.2]
  def up
    # Wallets are no longer represented as portfolio holdings.
    execute <<~SQL.squish
      DELETE FROM holdings
      WHERE asset_id IN (
        SELECT assets.id FROM assets
        INNER JOIN asset_types ON asset_types.id = assets.asset_type_id
        WHERE asset_types.key = 'wallet'
      )
    SQL

    change_column_null :transactions, :portfolio_id, true
    remove_reference :portfolios, :base_currency, foreign_key: { to_table: :currencies }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Cannot restore portfolio base_currency or wallet holdings without data"
  end
end
