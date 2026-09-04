# frozen_string_literal: true

# Multi-tenancy: give every user-owned table a user_id and backfill existing rows
# to the sole data owner. Structural enum tables (transaction_types, asset_types,
# target_types, category_types, price_sources, fund_types) stay global — the code
# references them by hardcoded key and every account needs them.
#
# Stage A: user_id is nullable here; ownership is auto-assigned by the app going
# forward. A later migration enforces NOT NULL + per-user uniqueness once verified.
class ScopeEntitiesToUser < ActiveRecord::Migration[7.2]
  TABLES = %w[
    assets asset_prices index_prices
    holdings transactions portfolio_targets portfolio_management_style_targets
    portfolio_snapshots asset_lots lot_closures purification_entries
    sectors specialities categories market_indices stock_purposes
    fund_styles management_styles
    currencies exchange_rates sector_targets zaka_payments
    zaka_settings free_cash_targets core_scoring_settings
  ].freeze

  def up
    owner_id = select_value("SELECT user_id FROM portfolios ORDER BY id LIMIT 1") ||
               select_value("SELECT id FROM users ORDER BY id LIMIT 1")

    unless column_exists?(:users, :admin)
      add_column :users, :admin, :boolean, default: false, null: false
      execute("UPDATE users SET admin = TRUE WHERE id = #{owner_id.to_i}") if owner_id
    end

    TABLES.each do |t|
      next unless table_exists?(t)
      next if column_exists?(t, :user_id)

      add_reference t, :user, foreign_key: true, index: true, null: true
      if owner_id
        execute("UPDATE #{quote_table_name(t)} SET user_id = #{owner_id.to_i} WHERE user_id IS NULL")
      end
    end
  end

  def down
    remove_column :users, :admin if column_exists?(:users, :admin)
    TABLES.each do |t|
      next unless table_exists?(t) && column_exists?(t, :user_id)

      remove_reference t, :user, foreign_key: true
    end
  end
end
