# frozen_string_literal: true

# Stage B: now that every user-owned row has an owner (stage A), enforce it at the
# database level and make the reference-key/code uniqueness per-user, so a second
# account can reuse codes/keys freely.
class EnforceUserScopeAndUniqueness < ActiveRecord::Migration[7.2]
  SCOPED = %w[
    assets asset_prices index_prices
    holdings transactions portfolio_targets portfolio_management_style_targets
    portfolio_snapshots asset_lots lot_closures purification_entries
    sectors specialities categories market_indices stock_purposes
    fund_styles management_styles
    currencies exchange_rates sector_targets zaka_payments
    zaka_settings free_cash_targets core_scoring_settings
  ].freeze

  # [table, old global unique index name, new per-user columns]
  PER_USER_UNIQUE = [
    [:assets,            "index_assets_on_code",            %i[user_id code]],
    [:currencies,        "index_currencies_on_code",        %i[user_id code]],
    [:market_indices,    "index_market_indices_on_code",    %i[user_id code]],
    [:sectors,           "index_sectors_on_key",            %i[user_id key]],
    [:specialities,      "index_specialities_on_key",       %i[user_id key]],
    [:stock_purposes,    "index_stock_purposes_on_key",     %i[user_id key]],
    [:fund_styles,       "index_fund_styles_on_key",        %i[user_id key]],
    [:management_styles, "index_management_styles_on_key",  %i[user_id key]]
  ].freeze

  def up
    owner_id = select_value("SELECT id FROM users WHERE admin = TRUE ORDER BY id LIMIT 1") ||
               select_value("SELECT user_id FROM portfolios ORDER BY id LIMIT 1")

    SCOPED.each do |t|
      next unless table_exists?(t) && column_exists?(t, :user_id)

      execute("UPDATE #{quote_table_name(t)} SET user_id = #{owner_id.to_i} WHERE user_id IS NULL") if owner_id
      change_column_null t, :user_id, false
    end

    PER_USER_UNIQUE.each do |table, old_name, cols|
      next unless table_exists?(table)

      remove_index table, name: old_name if index_name_exists?(table, old_name)
      add_index table, cols, unique: true unless index_exists?(table, cols, unique: true)
    end

    # One base currency per user (was: one globally).
    if table_exists?(:currencies)
      remove_index :currencies, name: "index_currencies_one_base" if index_name_exists?(:currencies, "index_currencies_one_base")
      unless index_name_exists?(:currencies, "index_currencies_one_base_per_user")
        add_index :currencies, :user_id, unique: true, where: "is_base = true", name: "index_currencies_one_base_per_user"
      end
    end
  end

  def down
    # Restore global unique indexes (best-effort) and drop NOT NULL.
    PER_USER_UNIQUE.each do |table, old_name, cols|
      next unless table_exists?(table)

      remove_index table, cols if index_exists?(table, cols, unique: true)
      col = cols.last
      add_index table, col, unique: true, name: old_name unless index_name_exists?(table, old_name)
    end

    if table_exists?(:currencies)
      remove_index :currencies, name: "index_currencies_one_base_per_user" if index_name_exists?(:currencies, "index_currencies_one_base_per_user")
      add_index :currencies, :is_base, unique: true, where: "(is_base = true)", name: "index_currencies_one_base" unless index_name_exists?(:currencies, "index_currencies_one_base")
    end

    SCOPED.each do |t|
      next unless table_exists?(t) && column_exists?(t, :user_id)

      change_column_null t, :user_id, true
    end
  end
end
