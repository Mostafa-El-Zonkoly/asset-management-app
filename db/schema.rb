# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_06_10_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "asset_prices", force: :cascade do |t|
    t.bigint "asset_id", null: false
    t.decimal "price", precision: 20, scale: 8, null: false
    t.bigint "currency_id", null: false
    t.date "date", null: false
    t.bigint "price_source_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_id", "currency_id", "date"], name: "index_asset_prices_unique_day", unique: true
    t.index ["asset_id"], name: "index_asset_prices_on_asset_id"
    t.index ["currency_id"], name: "index_asset_prices_on_currency_id"
    t.index ["price_source_id"], name: "index_asset_prices_on_price_source_id"
  end

  create_table "asset_types", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_asset_types_on_key", unique: true
  end

  create_table "assets", force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.bigint "category_id", null: false
    t.bigint "asset_type_id", null: false
    t.bigint "currency_id", null: false
    t.bigint "stock_purpose_id"
    t.bigint "sector_id"
    t.bigint "speciality_id"
    t.bigint "fund_type_id"
    t.bigint "fund_style_id"
    t.bigint "management_style_id"
    t.bigint "market_index_id"
    t.decimal "static_target", precision: 20, scale: 8
    t.text "notes"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "zaka_percentage", precision: 8, scale: 4, default: "0.0", null: false
    t.string "price_provider"
    t.string "price_provider_key"
    t.string "price_provider_link"
    t.index ["asset_type_id"], name: "index_assets_on_asset_type_id"
    t.index ["category_id"], name: "index_assets_on_category_id"
    t.index ["code"], name: "index_assets_on_code", unique: true
    t.index ["currency_id"], name: "index_assets_on_currency_id"
    t.index ["fund_style_id"], name: "index_assets_on_fund_style_id"
    t.index ["fund_type_id"], name: "index_assets_on_fund_type_id"
    t.index ["management_style_id"], name: "index_assets_on_management_style_id"
    t.index ["market_index_id"], name: "index_assets_on_market_index_id"
    t.index ["price_provider"], name: "index_assets_on_price_provider"
    t.index ["sector_id"], name: "index_assets_on_sector_id"
    t.index ["speciality_id"], name: "index_assets_on_speciality_id"
    t.index ["stock_purpose_id"], name: "index_assets_on_stock_purpose_id"
  end

  create_table "categories", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "category_type_id", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_type_id"], name: "index_categories_on_category_type_id"
  end

  create_table "category_types", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_category_types_on_key", unique: true
  end

  create_table "currencies", force: :cascade do |t|
    t.string "code", null: false
    t.string "name", null: false
    t.string "symbol", null: false
    t.boolean "is_base", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_currencies_on_code", unique: true
    t.index ["is_base"], name: "index_currencies_one_base", unique: true, where: "(is_base = true)"
  end

  create_table "exchange_rates", force: :cascade do |t|
    t.bigint "currency_id", null: false
    t.bigint "base_currency_id", null: false
    t.decimal "rate", precision: 20, scale: 8, null: false
    t.date "date", null: false
    t.bigint "price_source_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["base_currency_id"], name: "index_exchange_rates_on_base_currency_id"
    t.index ["currency_id", "base_currency_id", "date"], name: "index_exchange_rates_unique_pair_date", unique: true
    t.index ["currency_id"], name: "index_exchange_rates_on_currency_id"
    t.index ["price_source_id"], name: "index_exchange_rates_on_price_source_id"
  end

  create_table "free_cash_targets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "target_percentage", precision: 8, scale: 4
  end

  create_table "fund_styles", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_fund_styles_on_key", unique: true
  end

  create_table "fund_types", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_fund_types_on_key", unique: true
  end

  create_table "holdings", force: :cascade do |t|
    t.bigint "portfolio_id", null: false
    t.bigint "asset_id", null: false
    t.decimal "quantity", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "average_buy_price", precision: 20, scale: 8
    t.bigint "currency_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_id"], name: "index_holdings_on_asset_id"
    t.index ["currency_id"], name: "index_holdings_on_currency_id"
    t.index ["portfolio_id", "asset_id"], name: "index_holdings_on_portfolio_id_and_asset_id", unique: true
    t.index ["portfolio_id"], name: "index_holdings_on_portfolio_id"
  end

  create_table "index_prices", force: :cascade do |t|
    t.bigint "market_index_id", null: false
    t.decimal "price", precision: 20, scale: 8, null: false
    t.date "date", null: false
    t.bigint "price_source_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["market_index_id", "date"], name: "index_index_prices_on_market_index_id_and_date", unique: true
    t.index ["market_index_id"], name: "index_index_prices_on_market_index_id"
    t.index ["price_source_id"], name: "index_index_prices_on_price_source_id"
  end

  create_table "management_styles", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_management_styles_on_key", unique: true
  end

  create_table "market_indices", force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.text "description"
    t.bigint "currency_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_market_indices_on_code", unique: true
    t.index ["currency_id"], name: "index_market_indices_on_currency_id"
  end

  create_table "portfolio_management_style_targets", force: :cascade do |t|
    t.bigint "portfolio_id", null: false
    t.bigint "management_style_id", null: false
    t.decimal "target_percentage", precision: 8, scale: 4
    t.decimal "target_amount", precision: 20, scale: 8
    t.bigint "target_type_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["management_style_id"], name: "idx_on_management_style_id_d3f17f207c"
    t.index ["portfolio_id", "management_style_id"], name: "idx_pmst_on_portfolio_and_style", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_management_style_targets_on_portfolio_id"
    t.index ["target_type_id"], name: "index_portfolio_management_style_targets_on_target_type_id"
  end

  create_table "portfolio_snapshots", force: :cascade do |t|
    t.bigint "portfolio_id", null: false
    t.decimal "total_value", precision: 20, scale: 8, null: false
    t.bigint "currency_id", null: false
    t.date "date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["currency_id"], name: "index_portfolio_snapshots_on_currency_id"
    t.index ["portfolio_id", "date"], name: "index_portfolio_snapshots_on_portfolio_id_and_date", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_snapshots_on_portfolio_id"
  end

  create_table "portfolio_targets", force: :cascade do |t|
    t.bigint "portfolio_id", null: false
    t.bigint "category_id", null: false
    t.decimal "target_percentage", precision: 8, scale: 4
    t.decimal "target_amount", precision: 20, scale: 8
    t.bigint "target_type_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id"], name: "index_portfolio_targets_on_category_id"
    t.index ["portfolio_id", "category_id"], name: "index_portfolio_targets_on_portfolio_id_and_category_id", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_targets_on_portfolio_id"
    t.index ["target_type_id"], name: "index_portfolio_targets_on_target_type_id"
  end

  create_table "portfolios", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "whole_target_type_id"
    t.decimal "whole_target_percentage", precision: 8, scale: 4
    t.decimal "whole_target_amount", precision: 20, scale: 8
    t.boolean "include_in_combined_percent", default: true, null: false
    t.string "key"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_portfolios_on_user_id"
    t.index ["whole_target_type_id"], name: "index_portfolios_on_whole_target_type_id"
  end

  create_table "price_sources", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_price_sources_on_key", unique: true
  end

  create_table "sector_targets", force: :cascade do |t|
    t.bigint "sector_id", null: false
    t.decimal "target_percentage", precision: 8, scale: 4, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sector_id"], name: "index_sector_targets_on_sector_id"
  end

  create_table "sectors", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_sectors_on_key", unique: true
  end

  create_table "specialities", force: :cascade do |t|
    t.bigint "sector_id", null: false
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_specialities_on_key", unique: true
    t.index ["sector_id"], name: "index_specialities_on_sector_id"
  end

  create_table "stock_purposes", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_stock_purposes_on_key", unique: true
  end

  create_table "target_types", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_target_types_on_key", unique: true
  end

  create_table "transaction_types", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_transaction_types_on_key", unique: true
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "portfolio_id"
    t.bigint "asset_id", null: false
    t.bigint "transaction_type_id", null: false
    t.decimal "quantity", precision: 20, scale: 8, default: "0.0", null: false
    t.decimal "price_per_unit", precision: 20, scale: 8
    t.decimal "total_amount", precision: 20, scale: 8, null: false
    t.bigint "currency_id", null: false
    t.datetime "date", null: false
    t.bigint "related_wallet_id"
    t.bigint "transfer_to_wallet_id"
    t.decimal "realised_gain", precision: 20, scale: 8
    t.text "notes"
    t.uuid "transfer_pair_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "exchange_rate_at_transaction", precision: 20, scale: 8
    t.index ["asset_id"], name: "index_transactions_on_asset_id"
    t.index ["currency_id"], name: "index_transactions_on_currency_id"
    t.index ["portfolio_id", "date"], name: "index_transactions_on_portfolio_id_and_date"
    t.index ["portfolio_id"], name: "index_transactions_on_portfolio_id"
    t.index ["related_wallet_id"], name: "index_transactions_on_related_wallet_id"
    t.index ["transaction_type_id"], name: "index_transactions_on_transaction_type_id"
    t.index ["transfer_pair_id"], name: "index_transactions_on_transfer_pair_id"
    t.index ["transfer_to_wallet_id"], name: "index_transactions_on_transfer_to_wallet_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "zaka_payments", force: :cascade do |t|
    t.date "paid_on", null: false
    t.decimal "amount", precision: 20, scale: 8, null: false
    t.bigint "currency_id", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["currency_id"], name: "index_zaka_payments_on_currency_id"
    t.index ["paid_on", "id"], name: "index_zaka_payments_on_paid_on_and_id", order: :desc
  end

  create_table "zaka_settings", force: :cascade do |t|
    t.bigint "nisab_asset_id"
    t.decimal "nisab_quantity", precision: 20, scale: 8
    t.decimal "rate_percentage", precision: 8, scale: 4, default: "2.5", null: false
    t.integer "payment_interval_days", default: 354, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["nisab_asset_id"], name: "index_zaka_settings_on_nisab_asset_id"
  end

  add_foreign_key "asset_prices", "assets"
  add_foreign_key "asset_prices", "currencies"
  add_foreign_key "asset_prices", "price_sources"
  add_foreign_key "assets", "asset_types"
  add_foreign_key "assets", "categories"
  add_foreign_key "assets", "currencies"
  add_foreign_key "assets", "fund_styles"
  add_foreign_key "assets", "fund_types"
  add_foreign_key "assets", "management_styles"
  add_foreign_key "assets", "market_indices"
  add_foreign_key "assets", "sectors"
  add_foreign_key "assets", "specialities"
  add_foreign_key "assets", "stock_purposes"
  add_foreign_key "categories", "category_types"
  add_foreign_key "exchange_rates", "currencies"
  add_foreign_key "exchange_rates", "currencies", column: "base_currency_id"
  add_foreign_key "exchange_rates", "price_sources"
  add_foreign_key "holdings", "assets"
  add_foreign_key "holdings", "currencies"
  add_foreign_key "holdings", "portfolios"
  add_foreign_key "index_prices", "market_indices"
  add_foreign_key "index_prices", "price_sources"
  add_foreign_key "market_indices", "currencies"
  add_foreign_key "portfolio_management_style_targets", "management_styles"
  add_foreign_key "portfolio_management_style_targets", "portfolios"
  add_foreign_key "portfolio_management_style_targets", "target_types"
  add_foreign_key "portfolio_snapshots", "currencies"
  add_foreign_key "portfolio_snapshots", "portfolios"
  add_foreign_key "portfolio_targets", "categories"
  add_foreign_key "portfolio_targets", "portfolios"
  add_foreign_key "portfolio_targets", "target_types"
  add_foreign_key "portfolios", "target_types", column: "whole_target_type_id"
  add_foreign_key "portfolios", "users"
  add_foreign_key "sector_targets", "sectors"
  add_foreign_key "specialities", "sectors"
  add_foreign_key "transactions", "assets"
  add_foreign_key "transactions", "assets", column: "related_wallet_id"
  add_foreign_key "transactions", "assets", column: "transfer_to_wallet_id"
  add_foreign_key "transactions", "currencies"
  add_foreign_key "transactions", "portfolios"
  add_foreign_key "transactions", "transaction_types"
  add_foreign_key "zaka_payments", "currencies"
  add_foreign_key "zaka_settings", "assets", column: "nisab_asset_id"
end
