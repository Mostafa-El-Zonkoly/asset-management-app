# frozen_string_literal: true

# Updates an existing transaction row plus portfolio holdings (and validates wallet-visible cash)
# so aggregates stay coherent. Transfer rows allow notes/date only.
class TransactionAmendService
  class Error < StandardError; end

  PERMITTED = %w[
    portfolio_id quantity price_per_unit total_amount currency_id date
    related_wallet_id transfer_to_wallet_id notes
  ].freeze

  FINANCIAL_KEYS = %w[portfolio_id quantity price_per_unit total_amount currency_id related_wallet_id transfer_to_wallet_id].freeze

  class << self
    def call!(transaction, attrs)
      new.call!(transaction, attrs)
    end
  end

  def call!(transaction, attrs)
    tx = PortfolioTransaction.includes(:transaction_type, :portfolio, :asset).lock.find(transaction.id)
    deltas = normalized_deltas(tx, attrs)
    return tx if deltas.empty?

    ActiveRecord::Base.transaction(requires_new: true) do
      apply_patch!(tx, deltas)
    end

    tx
  rescue WalletLedgerService::InsufficientFundsError
    raise Error, "Wallet balance cannot go negative."
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  private

  def apply_patch!(tx, deltas)
    return apply_transfer_metadata_only!(tx, deltas) if tx.transfer_transaction?

    stamp = deltas.key?("notes") ? { notes: deltas["notes"] } : {}
    date_attrs = stamped_date_attrs(tx, deltas)
    touching_financial = FINANCIAL_KEYS.any? { |k| deltas.key?(k) }

    unless touching_financial
      attrs = stamp.merge(date_attrs)
      return tx if attrs.blank?

      tx.assign_attributes(attrs)
      tx.save!
      return tx
    end

    raise Error, "This transaction cannot be amended." unless tx.financially_amendable?

    assert_row_valid!(tx, deltas)
    WalletLedgerService.assert_non_negative_balances_after_substitution!(tx, deltas)

    reverse_holdings!(tx)

    deltas.each_key do |column|
      next if PERMITTED.exclude?(column)

      write_column!(tx, column, deltas[column])
    end

    validate_row_numbers!(tx)
    forward_holdings!(tx)

    tx.save!
    tx
  end

  def apply_transfer_metadata_only!(tx, deltas)
    forbidden = deltas.keys.reject { |k| %w[notes date].include?(k) }
    unless forbidden.empty?
      raise Error, "Only date and notes can be edited on a transfer."
    end

    attrs = stamped_date_attrs(tx, deltas)
    attrs[:notes] = deltas["notes"] if deltas.key?("notes")
    tx.assign_attributes(attrs)
    tx.save!
    tx
  end

  def stamped_date_attrs(tx, deltas)
    return {} unless deltas.key?("date")

    { date: timezone_parse(deltas["date"]) || tx.date }
  end

  def timezone_parse(raw)
    return nil if raw.blank?

    parsed = ActiveSupport::TimeZone["UTC"].parse(raw.to_s) || Time.zone.parse(raw.to_s)
    raise Error, "Invalid date/time" unless parsed

    parsed
  end

  def normalized_deltas(tx, attrs)
    p = attrs.is_a?(ActionController::Parameters) ? attrs : ActionController::Parameters.new(attrs.presence || {})
    h = p.permit(PERMITTED).to_unsafe_h
    out = {}
    PERMITTED.each do |column|
      next unless h.key?(column)

      new_val = coerce_incoming(column, h[column])
      old_val = read_column(tx, column)
      next if values_equivalent?(column, new_val, old_val)

      out[column] = new_val
    end
    out
  end

  def coerce_incoming(column, raw)
    case column
    when "portfolio_id", "currency_id", "related_wallet_id", "transfer_to_wallet_id"
      raw.present? ? raw.to_i : nil
    when "quantity", "price_per_unit", "total_amount"
      BigDecimal(raw.to_s.presence || "0")
    else
      raw
    end
  end

  def read_column(tx, column)
    case column
    when "quantity", "price_per_unit", "total_amount"
      tx.public_send(column).to_d
    when "portfolio_id", "currency_id", "related_wallet_id", "transfer_to_wallet_id"
      tx.public_send(column)
    when "notes"
      tx.read_attribute_before_type_cast("notes")
    when "date"
      tx.date
    end
  end

  def values_equivalent?(column, new_val, old_val)
    case column
    when "notes"
      new_val.to_s == old_val.to_s
    when "portfolio_id", "currency_id", "related_wallet_id", "transfer_to_wallet_id"
      new_val.blank? ? old_val.nil? || old_val.blank? : new_val.to_i == old_val.to_i
    when "quantity", "price_per_unit", "total_amount"
      new_val.to_d == old_val.to_d
    when "date"
      return true if new_val.blank?

      other = timezone_parse(new_val.to_s)
      return false unless other && old_val.respond_to?(:strftime)

      # datetime-local submits minute precision; tolerate sub-minute drift
      other.utc.strftime("%Y%m%d%H%M") == old_val.utc.strftime("%Y%m%d%H%M")
    else
      new_val.to_s == old_val.to_s
    end
  end

  def write_column!(tx, column, value)
    case column
    when "notes"
      tx.notes = value
    when "date"
      tx.date = timezone_parse(value)
    else
      tx.write_attribute(column, value)
    end
  end

  # --- Ledger merge previews (hypothetical post-edit row attributes) ---
  def m_row(tx, deltas)
    tx.attributes.merge(deltas.stringify_keys)
  end

  def effective_price_for_row(qty, total, ppunit)
    return nil if qty.to_d.zero?

    ppunit.present? && ppunit.to_d.nonzero? ? ppunit.to_d : (total.to_d / qty.to_d)
  end

  def assert_row_valid!(tx, deltas)
    mr = m_row(tx, deltas)
    key = tx.transaction_type.key

    case key
    when "deposit", "withdrawal"
      wallet = Asset.find(mr.fetch("asset_id"))
      raise Error, "Deposit/withdrawal must target a wallet" unless wallet.wallet?

      assert_positive_total!(mr.fetch("total_amount").to_d)
      raise Error, "currency is required" if mr.fetch("currency_id").blank?

    when "buy"
      raise Error, "portfolio_id is required" if mr.fetch("portfolio_id").blank?

      raise Error, "portfolio not found" unless Portfolio.exists?(mr.fetch("portfolio_id"))

      asset = Asset.find(mr.fetch("asset_id"))
      raise Error, "buy applies to securities, not wallets" if asset.wallet?

      wallet_id = mr.fetch("related_wallet_id").presence&.to_i
      raise Error, "Wallet is required for buys" if wallet_id.blank?

      wallet = Asset.find(wallet_id)
      raise Error, "Funding wallet must be a wallet asset" unless wallet.wallet?

      qty = mr.fetch("quantity").to_d
      total = mr.fetch("total_amount").to_d
      raise Error, "Invalid amounts" if qty <= 0 || total <= 0

    when "sell"
      raise Error, "portfolio_id is required" if mr.fetch("portfolio_id").blank?

      raise Error, "portfolio not found" unless Portfolio.exists?(mr.fetch("portfolio_id"))

      asset = Asset.find(mr.fetch("asset_id"))
      raise Error, "sell applies to securities" if asset.wallet?

      wallet_id = mr.fetch("related_wallet_id").presence&.to_i
      raise Error, "Wallet is required for sells" if wallet_id.blank?

      wallet = Asset.find(wallet_id)
      raise Error, "Cash wallet is required" unless wallet.wallet?

      qty = mr.fetch("quantity").to_d
      total = mr.fetch("total_amount").to_d
      raise Error, "Invalid amounts" if qty <= 0 || total <= 0

    when "cash_dividend"
      raise Error, "portfolio_id is required" if mr.fetch("portfolio_id").blank?

      unless Portfolio.exists?(mr.fetch("portfolio_id"))
        raise Error, "portfolio not found"
      end

      wallet_id = mr.fetch("related_wallet_id").presence&.to_i
      raise Error, "Wallet is required" if wallet_id.blank?

      Asset.find(wallet_id).tap { |w| raise(Error, "Wallet required") unless w.wallet? }

      total = mr.fetch("total_amount").to_d
      raise Error, "Invalid amount" if total <= 0

    when "stock_dividend"
      raise Error, "portfolio_id is required" if mr.fetch("portfolio_id").blank?

      unless Portfolio.exists?(mr.fetch("portfolio_id"))
        raise Error, "portfolio not found"
      end

      asset = Asset.find(mr.fetch("asset_id"))
      raise Error, "Stock dividend applies to securities" if asset.wallet?

      qty = mr.fetch("quantity").to_d
      raise Error, "quantity must be positive" if qty <= 0

    when "deduction"
      raise Error, "portfolio_id is required" if mr.fetch("portfolio_id").blank?

      unless Portfolio.exists?(mr.fetch("portfolio_id"))
        raise Error, "portfolio not found"
      end

      asset = Asset.find(mr.fetch("asset_id"))
      raise Error, "Deduction applies to securities, not wallets" if asset.wallet?

      qty = mr.fetch("quantity").to_d
      raise Error, "quantity must be positive" if qty <= 0

    end
    true
  end

  def validate_row_numbers!(tx)
    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    case tx.transaction_type.key
    when "buy", "sell", "cash_dividend", "deposit", "withdrawal"
      raise Error, "quantity must not be negative" if qty.negative?

      raise Error, "invalid total" if total <= 0 && tx.transaction_type.key != "stock_dividend"
    when "deduction"
      raise Error, "quantity must be positive" if qty <= 0
    end
  end

  def assert_positive_total!(total)
    raise Error, "total must be positive" if total <= 0
  end

  def reverse_holdings!(tx)
    case tx.transaction_type.key
    when "buy"
      reverse_buy_holding!(tx)
    when "sell"
      reverse_sell_holding!(tx)
    when "stock_dividend"
      reverse_stock_dividend_holding!(tx)
    when "deduction"
      reverse_deduction_holding!(tx)
    end
    nil
  end

  def forward_holdings!(tx)
    case tx.transaction_type.key
    when "buy"
      apply_buy_holding!(tx)
    when "sell"
      tx.realised_gain = forward_sell_holding!(tx)
    when "stock_dividend"
      apply_stock_dividend_holding!(tx)
    when "deduction"
      apply_deduction_holding!(tx)
    end
    nil
  end

  def reverse_buy_holding!(tx)
    pid = tx.portfolio_id
    raise Error, "Transaction has no portfolio" if pid.blank?

    portfolio = Portfolio.lock.find(pid)
    asset = Asset.find(tx.asset_id)
    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    raise Error, "invalid buy row" if qty <= 0 || total <= 0

    price = effective_price_for_row(qty, total, tx.price_per_unit&.to_d)
    holding = Holding.lock.find_by(portfolio:, asset:)
    raise Error, "No holding found to reverse this buy" unless holding

    q = holding.quantity.to_d
    raise Error, "Insufficient quantity held to unwind this buy" if q < qty

    avg = holding.average_buy_price&.to_d || 0.to_d
    new_q = q - qty
    new_avg =
      if new_q.zero?
        nil
      else
        numer = (q * avg) - (qty * price)
        raise Error, "Cannot unwind buy: inconsistent cost basis" if numer.negative?

        numer / new_q
      end

    holding.update!(quantity: new_q, average_buy_price: new_avg)
  end

  def apply_buy_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    raise Error, "Buy does not apply to wallets" if asset.wallet?

    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    raise Error, "Invalid amounts on buy amend" if qty <= 0 || total <= 0

    price = effective_price_for_row(qty, total, tx.price_per_unit&.to_d)
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
    raise Error, "Invalid quantity on sell" if qty <= 0

    holding = Holding.lock.find_by!(portfolio:, asset:)
    new_q = holding.quantity.to_d + qty

    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)
  end

  def forward_sell_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    qty = tx.quantity.to_d
    total = tx.total_amount.to_d
    raise Error, "Invalid amounts on sell amend" if qty <= 0 || total <= 0

    holding = lock_holding!(portfolio, asset, tx.currency_id)
    raise Error, "Insufficient quantity to realise this sell" if holding.quantity.to_d < qty

    price = effective_price_for_row(qty, total, tx.price_per_unit&.to_d)
    avg = holding.average_buy_price&.to_d || 0.to_d
    realised = (price - avg) * qty

    new_q = holding.quantity.to_d - qty
    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)

    realised
  end

  def reverse_stock_dividend_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    qty_div = tx.quantity.to_d
    raise Error, "Invalid dividend quantity" if qty_div <= 0

    holding = Holding.lock.find_by!(portfolio:, asset:)
    qty_after = holding.quantity.to_d
    qty_before = qty_after - qty_div
    raise Error, "Insufficient quantity to unwind dividend" if qty_before.negative?

    avg_after = holding.average_buy_price&.to_d
    if avg_after.blank? || avg_after.zero?
      holding.update!(quantity: qty_before, average_buy_price: qty_before.zero? ? nil : holding.average_buy_price)
      return
    end

    preserved_cost = qty_after * avg_after
    avg_before = qty_before.zero? ? nil : (preserved_cost / qty_before)
    holding.update!(quantity: qty_before, average_buy_price: avg_before)
  end

  def apply_stock_dividend_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)

    qty = tx.quantity.to_d
    raise Error, "Invalid quantity on stock dividend amend" if qty <= 0

    holding = lock_holding!(portfolio, asset, tx.currency_id)
    old_q = holding.quantity.to_d
    old_avg = holding.average_buy_price&.to_d || 0.to_d
    new_q = old_q + qty

    preserved_cost = old_q * old_avg
    new_avg = new_q.zero? ? nil : (preserved_cost / new_q)

    holding.update!(quantity: new_q, average_buy_price: new_avg)
  end

  def reverse_deduction_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    qty = tx.quantity.to_d
    raise Error, "Invalid quantity on deduction" if qty <= 0

    holding = Holding.lock.find_by!(portfolio:, asset:)
    holding.update!(quantity: holding.quantity.to_d + qty)
  end

  def apply_deduction_holding!(tx)
    portfolio = Portfolio.lock.find(tx.portfolio_id)
    asset = Asset.find(tx.asset_id)
    qty = tx.quantity.to_d
    raise Error, "Invalid quantity on deduction" if qty <= 0

    holding = lock_holding!(portfolio, asset, tx.currency_id)
    raise Error, "Insufficient quantity for deduction" if holding.quantity.to_d < qty

    new_q = holding.quantity.to_d - qty
    holding.update!(quantity: new_q, average_buy_price: new_q.zero? ? nil : holding.average_buy_price)
  end

  def lock_holding!(portfolio, asset, currency_id)
    Holding.lock.find_or_create_by!(portfolio:, asset:) do |h|
      h.quantity = 0
      h.currency_id = currency_id
    end
  end
end
