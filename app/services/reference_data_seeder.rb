# frozen_string_literal: true

# Provisions a new (or existing empty) user with the reference framework they need
# to use the app: currencies (with a base), sector/speciality taxonomy, the
# classification lookups, and starter categories. Financial data (portfolios,
# holdings, transactions) is left for the user to create.
#
# Structural enums (asset_types, category_types, transaction_types, target_types,
# price_sources, fund_types) are global and shared, so they are not seeded here.
module ReferenceDataSeeder
  SECTORS = %w[
    materials financial construction food_and_beverage healthcare
    technology energy real_estate other
  ].freeze

  SPECIALITIES = {
    "financial"  => %w[banks e_finance insurance],
    "healthcare" => %w[hospitals],
    "technology" => %w[retail telecom]
  }.freeze

  STOCK_PURPOSES  = %w[dividend growth temporary].freeze
  FUND_STYLES     = %w[index general].freeze
  MANAGEMENT_STYLES = %w[passive active].freeze

  module_function

  # Idempotent: does nothing if the user already has currencies.
  def seed_for(user)
    return if user.nil?

    with_tenant(user) do
      return if Currency.exists?

      seed_currencies
      seed_lookup(Sector, SECTORS)
      seed_specialities
      seed_lookup(StockPurpose, STOCK_PURPOSES)
      seed_lookup(FundStyle, FUND_STYLES)
      seed_lookup(ManagementStyle, MANAGEMENT_STYLES)
      seed_categories
    end
  end

  def with_tenant(user)
    previous = Current.user
    Current.user = user
    yield
  ensure
    Current.user = previous
  end

  def seed_currencies
    Currency.find_or_create_by!(code: "EGP") do |c|
      c.name = "Egyptian Pound"
      c.symbol = "E£"
      c.is_base = true
    end
    Currency.find_or_create_by!(code: "USD") do |c|
      c.name = "US Dollar"
      c.symbol = "$"
      c.is_base = false
    end
  end

  def seed_lookup(model, keys)
    keys.each_with_index do |key, i|
      model.find_or_create_by!(key: key) do |r|
        r.label = key.tr("_", " ").capitalize
        r.position = i
        r.active = true
      end
    end
  end

  def seed_specialities
    SPECIALITIES.each do |sector_key, spec_keys|
      sector = Sector.find_by(key: sector_key)
      next unless sector

      spec_keys.each_with_index do |key, i|
        Speciality.find_or_create_by!(key: key) do |s|
          s.sector = sector
          s.label = key.tr("_", " ").capitalize
          s.position = i
          s.active = true
        end
      end
    end
  end

  def seed_categories
    stocks = CategoryType.find_by(key: "stocks")
    wallets = CategoryType.find_by(key: "wallets")
    Category.find_or_create_by!(name: "EGX Stocks") { |c| c.category_type = stocks } if stocks
    Category.find_or_create_by!(name: "Cash") { |c| c.category_type = wallets } if wallets
  end
end
