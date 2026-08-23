# frozen_string_literal: true

# Updates portfolio_id on an existing transaction and adjusts holdings so ledger state stays consistent.
# Wallet cash flows are unchanged (same related_wallet_id / amounts); only portfolio-scoped stock rows move.
class TransactionPortfolioUpdateService
  class Error < StandardError; end

  class << self
    def call!(transaction, portfolio_id:)
      new.call!(transaction, portfolio_id: portfolio_id)
    end
  end

  def call!(transaction, portfolio_id:)
    tx = transaction.is_a?(PortfolioTransaction) ? transaction : PortfolioTransaction.find(transaction)
    new_pid = portfolio_id.presence

    ActiveRecord::Base.transaction do
      tx.lock!
      assert_editable_type!(tx)
      validate_new_portfolio!(tx, new_pid)
      return tx if tx.portfolio_id == new_pid

      case tx.transaction_type.key
      when "cash_dividend"
        tx.update!(portfolio_id: new_pid)
      when "buy"
        reverse_buy_holding!(tx)
        tx.update!(portfolio_id: new_pid)
        apply_buy_holding!(tx)
      when "sell"
        realised = reverse_and_reapply_sell!(tx, new_pid)
        tx.update!(portfolio_id: new_pid, realised_gain: realised)
      when "stock_dividend"
        reverse_stock_dividend_holding!(tx)
        tx.update!(portfolio_id: new_pid)
        apply_stock_dividend_holding!(tx)
      else
        raise Error, "Unsupported transaction type: #{tx.transaction_type.key}"
      end
      tx
    end
  end

  private

  def assert_editable_type!(tx)
    key = tx.transaction_type.key
    return unless %w[deposit withdrawal transfer].include?(key)

    raise Error, "Wallet-only transactions do not use a portfolio"
  end

  def validate_new_portfolio!(tx, new_pid)
    raise Error, "Portfolio is required for this transaction type" if new_pid.blank?

    Portfolio.find(new_pid)
  end

  def effective_price(tx, qty, total)
    tx.price_per_unit.present? ? tx.price_per_unit.to_d : (total / qty)
  end

  def lock_holding!(portfolio, asset, currency_id)
    Holding.lock.find_or_create_by!(portfolio: portfolio, asset: asset) do |h|
      h.quantity = 0
      h.currency_id = currency_id
    end
  end

  def reverse_buy_holding!(tx)
    pid = tx.portfolio_id
    raise Error, "Transaction has no portfolio to move from" if pid.blank?

    portfolio = Portfolio.lock.find(pid)
    asset = Asset.find(tx.asset_id)
    raise Error, "Buy does not apply to wallet assets" if asset.wallet?

    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    raise Error, "Invalid amounts on transaction" if qty <= 0 || total <= 0

    price = effective_price(tx, qty, total)
    holding = Holding.lock.find_by(portfolio: portfolio, asset: asset)
    raise Error, "No holding found to reverse this buy" unless holding

    q = holding.quantity.to_d
    raise Error, "Holding quantity is too low to reverse this buy" if q < qty

    avg = holding.average_buy_price&.to_d || 0.to_d
    new_q = q - qty
    new_avg =
      if new_q.zero?
        nil
      else
        numer = (q * avg) - (qty * price)
        raise Error, "Cannot reverse buy: inconsistent cost basis" if numer.negative?

        numer / new_q
      end

    holding.update!(quantity: new_q, average_buy_price: new_avg)
  end

  def apply_buy_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    raise Error, "Buy does not apply to wallet assets" if asset.wallet?

    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    raise Error, "Invalid amounts on transaction" if qty <= 0 || total <= 0

    price = effective_price(tx, qty, total)
    holding = lock_holding!(portfolio, asset, tx.currency_id)
    old_q = holding.quantity.to_d
    old_avg = holding.average_buy_price&.to_d || 0.to_d
    new_q = old_q + qty
    new_avg = new_q.zero? ? nil : ((old_q * old_avg) + (qty * price)) / new_q
    holding.update!(quantity: new_q, average_buy_price: new_avg)
  end

  def reverse_sell_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    qty = tx.quantity.to_d
    raise Error, "Invalid quantity on transaction" if qty <= 0

    holding = Holding.lock.find_by!(portfolio: portfolio, asset: asset)
    new_q = holding.quantity.to_d + qty
    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)
  end

  def forward_sell_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    raise Error, "Invalid amounts on transaction" if qty <= 0 || total <= 0

    holding = lock_holding!(portfolio, asset, tx.currency_id)
    raise Error, "Insufficient quantity in target portfolio" if holding.quantity.to_d < qty

    price = effective_price(tx, qty, total)
    avg = holding.average_buy_price&.to_d || 0.to_d
    realised = (price - avg) * qty

    new_q = holding.quantity.to_d - qty
    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)

    realised
  end

  def reverse_and_reapply_sell!(tx, new_pid)
    reverse_sell_holding!(tx)
    tx.assign_attributes(portfolio_id: new_pid)
    forward_sell_holding!(tx)
  end

  def reverse_stock_dividend_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    raise Error, "Stock dividend does not apply to wallet assets" if asset.wallet?

    qty = tx.quantity.to_d
    raise Error, "Invalid quantity on transaction" if qty <= 0

    holding = Holding.lock.find_by!(portfolio: portfolio, asset: asset)
    new_q = holding.quantity.to_d - qty
    raise Error, "Holding quantity is too low to reverse this stock dividend" if new_q.negative?

    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)
  end

  def apply_stock_dividend_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    raise Error, "Stock dividend does not apply to wallet assets" if asset.wallet?

    qty = tx.quantity.to_d
    raise Error, "Invalid quantity on transaction" if qty <= 0

    holding = lock_holding!(portfolio, asset, tx.currency_id)
    holding.update!(quantity: holding.quantity.to_d + qty)
  end
end
