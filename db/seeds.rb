# frozen_string_literal: true

def seed_lookup(model, rows)
  rows.each_with_index do |row, i|
    key, label = row.is_a?(Array) ? row : [ row[:key], row[:label] ]
    model.find_or_initialize_by(key: key).tap do |r|
      r.label = label
      r.position = i
      r.active = true
      r.save!
    end
  end
end

seed_lookup(AssetType, [
  %w[direct_stock Direct\ stock],
  %w[mutual_fund Mutual\ fund],
  %w[savings_account Savings\ account],
  %w[wallet Wallet]
])

seed_lookup(StockPurpose, [
  %w[dividend Dividend],
  %w[growth Growth],
  %w[temporary Temporary]
])

seed_lookup(Sector, [
  %w[materials Materials],
  %w[financial Financial],
  %w[construction Construction],
  %w[food_and_beverage Food\ and\ beverage],
  %w[healthcare Healthcare],
  %w[technology Technology],
  %w[energy Energy],
  %w[real_estate Real\ estate],
  %w[other Other]
])

financial = Sector.find_by!(key: "financial")
healthcare = Sector.find_by!(key: "healthcare")
technology = Sector.find_by!(key: "technology")

[
  [ financial, "banks", "Banks" ],
  [ financial, "e_finance", "E-finance" ],
  [ financial, "insurance", "Insurance" ],
  [ healthcare, "hospitals", "Hospitals" ],
  [ technology, "retail", "Retail" ],
  [ technology, "telecom", "Telecom" ]
].each_with_index do |(sector, key, label), i|
  Speciality.find_or_initialize_by(key: key).tap do |s|
    s.sector = sector
    s.label = label
    s.position = i
    s.active = true
    s.save!
  end
end

seed_lookup(FundType, [
  %w[stock_fund Stock\ fund],
  %w[metal_fund Metal\ fund],
  %w[balanced_fund Balanced\ fund],
  %w[money_market_fund Money\ market\ fund]
])

seed_lookup(FundStyle, [
  %w[index Index],
  %w[general General]
])

seed_lookup(ManagementStyle, [
  %w[passive Passive],
  %w[active Active]
])

seed_lookup(CategoryType, [
  %w[metals Metals],
  %w[stocks Stocks],
  %w[money Money],
  %w[wallets Wallets]
])

seed_lookup(TransactionType, [
  %w[deposit Deposit],
  %w[withdrawal Withdrawal],
  %w[transfer Transfer],
  %w[buy Buy],
  %w[sell Sell],
  %w[stock_dividend Stock\ dividend],
  %w[cash_dividend Cash\ dividend],
  %w[deduction Deduction]
])

seed_lookup(PriceSource, [
  %w[manual Manual],
  %w[scraped Scraped]
])

seed_lookup(TargetType, [
  %w[percentage Percentage],
  %w[static_amount Static\ amount]
])

user = User.find_or_initialize_by(email: "m.zonkoly@gmail.com")
user.password = "P@ssw0rd"
user.password_confirmation = "P@ssw0rd"
user.save!

Currency.update_all(is_base: false)

egp = Currency.find_or_initialize_by(code: "EGP")
egp.assign_attributes(name: "Egyptian Pound", symbol: "E£", is_base: true)
egp.save!

usd = Currency.find_or_initialize_by(code: "USD")
usd.assign_attributes(name: "US Dollar", symbol: "$", is_base: false)
usd.save!

ct_stocks = CategoryType.find_by!(key: "stocks")
ct_wallets = CategoryType.find_by!(key: "wallets")

cat_stocks = Category.find_or_create_by!(name: "EGX Stocks") { |c| c.category_type = ct_stocks }
cat_cash = Category.find_or_create_by!(name: "Cash") { |c| c.category_type = ct_wallets }

at_stock = AssetType.find_by!(key: "direct_stock")
at_wallet = AssetType.find_by!(key: "wallet")
sector = Sector.find_by!(key: "financial")
manual = PriceSource.find_by!(key: "manual")

main_wallet = Asset.find_or_create_by!(code: "CASH_EGP") do |a|
  a.name = "EGP Cash Wallet"
  a.category = cat_cash
  a.asset_type = at_wallet
  a.currency = egp
end



portfolio = Portfolio.find_or_create_by!(name: "Main") do |p|
  p.description = "Demo portfolio"
end

deposit_type = TransactionType.find_by!(key: "deposit")
buy_type = TransactionType.find_by!(key: "buy")

unless PortfolioTransaction.exists?(asset_id: main_wallet.id, transaction_type: deposit_type)

end

unless PortfolioTransaction.exists?(portfolio_id: portfolio.id, transaction_type: buy_type)

end


PortfolioSnapshotService.record!(portfolio, as_of: Date.current)
