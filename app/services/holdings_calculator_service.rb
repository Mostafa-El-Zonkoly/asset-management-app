# frozen_string_literal: true

class HoldingsCalculatorService
  Result = Struct.new(
    :current_price,
    :current_value,
    :cost_basis,           # historical cost in base currency (at purchase-time FX rates)
    :unrealised_gain,      # total unrealised = price gain + fx gain
    :unrealised_gain_pct,
    :fx_gain,              # portion of unrealised from exchange rate movement
    :fx_gain_pct,
    :price_gain,           # portion of unrealised from asset price movement
    :price_gain_pct,
    :realised_gain,
    :realised_gain_pct,
    :total_gain,
    :total_gain_pct,
    :total_dividends,
    keyword_init: true
  )

  class << self
    def for_holding(holding)
      new(holding.portfolio).for_holding(holding)
    end
  end

  def initialize(portfolio)
    @portfolio = portfolio
    @base_id = Currency.reporting_currency_id
  end

  def for_holding(holding)
    asset = holding.asset
    raise ArgumentError, "Wallet assets are not portfolio holdings" if asset.wallet?

    qty = holding.quantity.to_d
    avg = holding.average_buy_price&.to_d || 0.to_d
    asset_ccy = asset.currency_id

    price = latest_asset_price(asset)
    current_local = price ? (price * qty) : 0.to_d
    current_value = convert_to_reporting(current_local, asset_ccy)

    # Compute the historical cost in base currency using each buy transaction's
    # recorded exchange rate (purchase-time rate), not today's rate.
    cost_basis = historical_cost_in_base(asset.id, asset_ccy, avg, qty)

    # Cost at current FX rate (same asset-currency amount, today's rate) — used to
    # isolate the two components of unrealised gain.
    cost_at_current_fx = convert_to_reporting(avg * qty, asset_ccy)

    # FX gain: what the original investment is worth in base currency due to rate change alone.
    fx_gain = cost_at_current_fx - cost_basis
    fx_gain_pct = gain_percent(fx_gain, cost_basis)

    # Price gain: what you made from the asset price moving (evaluated at current FX).
    price_gain = current_value - cost_at_current_fx
    price_gain_pct = gain_percent(price_gain, cost_at_current_fx)

    unrealised = fx_gain + price_gain
    unreal_pct = gain_percent(unrealised, cost_basis)

    realised_core = portfolio_realised_for_asset(asset.id)
    dividends = portfolio_dividends_for_asset(asset.id)
    realised = realised_core + dividends
    realised_pct = gain_percent(realised, cost_basis)

    total_gain_amount = realised + unrealised
    total_pct = gain_percent(total_gain_amount, cost_basis)

    Result.new(
      current_price: price,
      current_value: current_value,
      cost_basis: cost_basis,
      unrealised_gain: unrealised,
      unrealised_gain_pct: unreal_pct,
      fx_gain: fx_gain,
      fx_gain_pct: fx_gain_pct,
      price_gain: price_gain,
      price_gain_pct: price_gain_pct,
      realised_gain: realised,
      realised_gain_pct: realised_pct,
      total_gain: total_gain_amount,
      total_gain_pct: total_pct,
      total_dividends: dividends
    )
  end

  private

  # Returns historical cost in base currency.
  # For each buy transaction that has exchange_rate_at_transaction recorded, we use that rate.
  # If a buy has no stored rate (legacy row), we fall back to the current rate for that leg.
  def historical_cost_in_base(asset_id, asset_ccy, avg_buy_price, current_qty)
    buy_type = TransactionType.find_by(key: "buy")
    sell_type = TransactionType.find_by(key: "sell")
    stock_div_type = TransactionType.find_by(key: "stock_dividend")
    deduction_type = TransactionType.find_by(key: "deduction")

    # Replay buy/sell/stock_dividend/deduction transactions chronologically to reconstruct the
    # weighted average purchase-rate cost basis for the currently held quantity.
    txns = @portfolio.portfolio_transactions
      .where(asset_id: asset_id)
      .where(transaction_type_id: [ buy_type&.id, sell_type&.id, stock_div_type&.id, deduction_type&.id ].compact)
      .order(:date)

    # Running weighted sum: total cost paid in base currency for currently held qty.
    held_qty = 0.to_d
    held_cost_base = 0.to_d

    txns.each do |tx|
      qty = tx.quantity.to_d
      next if qty.zero?

      case tx.transaction_type_id
      when buy_type&.id
        price = tx.price_per_unit&.to_d&.nonzero? || (tx.total_amount.to_d / qty)
        rate = fx_rate_for_tx(tx, asset_ccy)
        # Accumulate total base-currency cost paid for units still held
        held_cost_base += price * qty * rate
        held_qty += qty

      when sell_type&.id
        # Reduce held cost proportionally (FIFO / average cost)
        if held_qty.positive?
          sold_fraction = [ qty / held_qty, 1.to_d ].min
          held_cost_base -= held_cost_base * sold_fraction
          held_qty = [ held_qty - qty, 0.to_d ].max
        end

      when stock_div_type&.id
        # Stock dividends add units at zero incremental cost (total cost preserved, avg diluted)
        held_qty += qty

      when deduction_type&.id
        # Deductions remove units proportionally (same as sell but no cash proceeds)
        if held_qty.positive?
          deducted_fraction = [ qty / held_qty, 1.to_d ].min
          held_cost_base -= held_cost_base * deducted_fraction
          held_qty = [ held_qty - qty, 0.to_d ].max
        end
      end
    end

    # If no buy transactions recorded (shouldn't happen), fall back to current-rate conversion
    return convert_to_reporting(avg_buy_price * current_qty, asset_ccy) if held_qty.zero?

    # Scale to current quantity (handles edge cases from rounding)
    return held_cost_base if current_qty.zero?

    held_cost_base * (current_qty / held_qty)
  rescue StandardError
    # Safety fallback: use current FX rate
    convert_to_reporting(avg_buy_price * current_qty, asset_ccy)
  end

  # Returns the FX rate stored on the transaction, or looks up historical rate.
  def fx_rate_for_tx(tx, asset_ccy)
    return 1.to_d if @base_id.blank? || asset_ccy == @base_id

    if tx.exchange_rate_at_transaction.present?
      tx.exchange_rate_at_transaction.to_d
    else
      CurrencyConversionService.rate_on_date(asset_ccy, @base_id, tx.date)
    end
  end

  def latest_asset_price(asset)
    asset.asset_prices.where(currency_id: asset.currency_id).order(date: :desc).first&.price&.to_d
  end

  def portfolio_realised_for_asset(asset_id)
    @portfolio.portfolio_transactions
      .where(asset_id: asset_id)
      .where.not(realised_gain: nil)
      .sum { |t| convert_to_reporting(t.realised_gain, t.currency_id) }
  end

  def portfolio_dividends_for_asset(asset_id)
    type = TransactionType.find_by(key: "cash_dividend")
    return 0.to_d unless type

    @portfolio.portfolio_transactions.where(asset_id: asset_id, transaction_type: type).sum do |t|
      convert_to_reporting(t.total_amount, t.currency_id)
    end
  end

  def convert_to_reporting(amount, from_currency_id)
    return amount.to_d if @base_id.blank?

    CurrencyConversionService.convert(amount, from_currency_id, @base_id)
  end

  def gain_percent(gain, cost_basis)
    return ((gain / cost_basis) * 100) if cost_basis.nonzero?
    return 100.to_d if gain.positive?
    return -100.to_d if gain.negative?

    0.to_d
  end
end
