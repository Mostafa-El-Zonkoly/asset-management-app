# frozen_string_literal: true

class TransactionProcessorService
  class Error < StandardError; end

  class << self
    def call!(attrs)
      new.call!(attrs)
    end
  end

  # attrs: portfolio_id (omit for wallet-only: deposit, withdrawal, transfer),
  #        asset_id, transaction_type_id (or key), quantity, price_per_unit, total_amount,
  #        currency_id, date, related_wallet_id, transfer_to_wallet_id, notes,
  #        for transfer only: also builds second leg via transfer_pair_id
  def call!(attrs)
    attrs = attrs.deep_symbolize_keys
    ActiveRecord::Base.transaction(requires_new: true) do
      type =
        if attrs[:transaction_type_id]
          TransactionType.find(attrs[:transaction_type_id])
        elsif attrs[:transaction_type]
          TransactionType.find_by!(key: attrs[:transaction_type].to_s)
        else
          raise Error, "transaction_type_id or transaction_type (key) is required"
        end

      case type.key
      when "buy" then apply_buy!(attrs)
      when "sell" then apply_sell!(attrs)
      when "cash_dividend" then apply_cash_dividend!(attrs)
      when "stock_dividend" then apply_stock_dividend!(attrs)
      when "deposit" then apply_deposit!(attrs)
      when "withdrawal" then apply_withdrawal!(attrs)
      when "transfer" then apply_transfer!(attrs)
      when "deduction" then apply_deduction!(attrs)
      else
        raise Error, "Unsupported transaction type: #{type.key}"
      end
    end
  end

  private

  def apply_buy!(attrs)
    raise Error, "portfolio_id is required for buys" if attrs[:portfolio_id].blank?

    portfolio = Portfolio.lock.find(attrs[:portfolio_id])
    asset = Asset.find(attrs[:asset_id])
    raise Error, "Buy applies to non-wallet assets" if asset.wallet?

    wallet = Asset.find(attrs[:related_wallet_id])
    raise Error, "Wallet required" unless wallet.wallet?

    total = attrs[:total_amount].to_d
    qty = attrs[:quantity].to_d
    raise Error, "Invalid amounts" if total <= 0 || qty <= 0

    available = WalletLedgerService.balance(wallet)
    raise Error, "Insufficient wallet balance" if available < total

    create_tx!(attrs.merge(transaction_type: TransactionType.find_by!(key: "buy")))

    holding = lock_holding!(portfolio, asset, attrs[:currency_id])
    old_q = holding.quantity.to_d
    old_avg = holding.average_buy_price&.to_d || 0.to_d
    price = attrs[:price_per_unit].present? ? attrs[:price_per_unit].to_d : (total / qty)
    new_q = old_q + qty
    new_avg = new_q.zero? ? nil : ((old_q * old_avg) + (qty * price)) / new_q
    holding.update!(quantity: new_q, average_buy_price: new_avg)
    nil
  end

  def apply_sell!(attrs)
    raise Error, "portfolio_id is required for sells" if attrs[:portfolio_id].blank?

    portfolio = Portfolio.lock.find(attrs[:portfolio_id])
    asset = Asset.find(attrs[:asset_id])
    raise Error, "Sell applies to non-wallet assets" if asset.wallet?

    wallet = Asset.find(attrs[:related_wallet_id])
    raise Error, "Wallet required" unless wallet.wallet?

    total = attrs[:total_amount].to_d
    qty = attrs[:quantity].to_d
    raise Error, "Invalid amounts" if total <= 0 || qty <= 0

    holding = lock_holding!(portfolio, asset, attrs[:currency_id])
    raise Error, "Insufficient quantity" if holding.quantity.to_d < qty

    price = attrs[:price_per_unit].present? ? attrs[:price_per_unit].to_d : (total / qty)
    avg = holding.average_buy_price&.to_d || 0.to_d
    realised = (price - avg) * qty

    create_tx!(attrs.merge(transaction_type: TransactionType.find_by!(key: "sell"), realised_gain: realised))

    new_q = holding.quantity.to_d - qty
    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)

    nil
  end

  def apply_cash_dividend!(attrs)
    raise Error, "portfolio_id is required" if attrs[:portfolio_id].blank?

    Portfolio.lock.find(attrs[:portfolio_id])
    wallet = Asset.find(attrs[:related_wallet_id])
    raise Error, "Wallet required" unless wallet.wallet?

    create_tx!(attrs.merge(transaction_type: TransactionType.find_by!(key: "cash_dividend")))
    nil
  end

  def apply_stock_dividend!(attrs)
    raise Error, "portfolio_id is required" if attrs[:portfolio_id].blank?

    portfolio = Portfolio.lock.find(attrs[:portfolio_id])
    asset = Asset.find(attrs[:asset_id])
    raise Error, "Stock dividend applies to non-wallet assets" if asset.wallet?

    qty = attrs[:quantity].to_d
    raise Error, "Quantity must be positive" if qty <= 0

    create_tx!(attrs.merge(
      transaction_type: TransactionType.find_by!(key: "stock_dividend"),
      total_amount: 0.to_d,
      price_per_unit: 0.to_d
    ))

    holding = lock_holding!(portfolio, asset, attrs[:currency_id])
    old_q = holding.quantity.to_d
    old_avg = holding.average_buy_price&.to_d || 0.to_d
    new_q = old_q + qty

    # Stock dividends add units at zero cost; keep historical cost fixed and
    # dilute the average buy price across the increased quantity.
    preserved_cost = old_q * old_avg
    new_avg = new_q.zero? ? nil : (preserved_cost / new_q)

    holding.update!(quantity: new_q, average_buy_price: new_avg)
    nil
  end

  def apply_deposit!(attrs)
    raise Error, "portfolio_id must be blank for deposits" if attrs[:portfolio_id].present?

    wallet = Asset.find(attrs[:asset_id])
    raise Error, "Deposit must target a wallet asset" unless wallet.wallet?

    create_tx!(attrs.merge(transaction_type: TransactionType.find_by!(key: "deposit")))
    nil
  end

  def apply_withdrawal!(attrs)
    raise Error, "portfolio_id must be blank for withdrawals" if attrs[:portfolio_id].present?

    wallet = Asset.find(attrs[:asset_id])
    raise Error, "Withdrawal must target a wallet asset" unless wallet.wallet?

    total = attrs[:total_amount].to_d
    available = WalletLedgerService.balance(wallet)
    raise Error, "Insufficient wallet balance" if available < total

    create_tx!(attrs.merge(transaction_type: TransactionType.find_by!(key: "withdrawal")))
    nil
  end

  def apply_transfer!(attrs)
    raise Error, "portfolio_id must be blank for transfers" if attrs[:portfolio_id].present?

    source = Asset.find(attrs[:asset_id])
    target = Asset.find(attrs[:transfer_to_wallet_id])
    raise Error, "Transfer requires two wallets" unless source.wallet? && target.wallet?

    total = attrs[:total_amount].to_d
    raise Error, "Invalid amount" if total <= 0

    available = WalletLedgerService.balance(source)
    raise Error, "Insufficient wallet balance" if available < total

    pair = attrs[:transfer_pair_id] || SecureRandom.uuid
    base = attrs.except(:transfer_pair_id)
    t_transfer = TransactionType.find_by!(key: "transfer")

    create_tx!(base.merge(
      transaction_type: t_transfer,
      transfer_pair_id: pair
    ))

    create_tx!(base.merge(
      transaction_type: t_transfer,
      asset_id: target.id,
      related_wallet_id: source.id,
      transfer_to_wallet_id: nil,
      transfer_pair_id: pair
    ))
    nil
  end

  def apply_deduction!(attrs)
    raise Error, "portfolio_id is required for deductions" if attrs[:portfolio_id].blank?

    portfolio = Portfolio.lock.find(attrs[:portfolio_id])
    asset = Asset.find(attrs[:asset_id])
    raise Error, "Deduction applies to non-wallet assets" if asset.wallet?

    qty = attrs[:quantity].to_d
    raise Error, "Quantity must be positive" if qty <= 0

    holding = lock_holding!(portfolio, asset, attrs[:currency_id])
    raise Error, "Insufficient quantity" if holding.quantity.to_d < qty

    create_tx!(attrs.merge(
      transaction_type: TransactionType.find_by!(key: "deduction"),
      total_amount: 0.to_d,
      price_per_unit: 0.to_d
    ))

    new_q = holding.quantity.to_d - qty
    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)
    nil
  end

  def create_tx!(attrs)
    type = attrs[:transaction_type]
    type = TransactionType.find_by!(key: type.to_s) if type.is_a?(String)

    date = attrs[:date] || Time.current
    currency_id = attrs[:currency_id]
    base_id = Currency.reporting_currency_id

    # Use explicitly provided rate, or look up historical rate for this date.
    fx_rate = if attrs[:exchange_rate_at_transaction].present?
      attrs[:exchange_rate_at_transaction].to_d
    else
      CurrencyConversionService.rate_on_date(currency_id.to_i, base_id.to_i, date)
    end

    PortfolioTransaction.create!(
      portfolio_id: attrs[:portfolio_id],
      asset_id: attrs[:asset_id],
      transaction_type: type,
      quantity: attrs.fetch(:quantity, 0).to_d,
      price_per_unit: attrs[:price_per_unit],
      total_amount: attrs[:total_amount].to_d,
      currency_id: currency_id,
      date: date,
      related_wallet_id: attrs[:related_wallet_id],
      transfer_to_wallet_id: attrs[:transfer_to_wallet_id],
      realised_gain: attrs[:realised_gain],
      notes: attrs[:notes],
      transfer_pair_id: attrs[:transfer_pair_id],
      exchange_rate_at_transaction: fx_rate
    )
  end

  def lock_holding!(portfolio, asset, currency_id)
    Holding.lock.find_or_create_by!(portfolio: portfolio, asset: asset) do |h|
      h.quantity = 0
      h.currency_id = currency_id
    end
  end
end
