# frozen_string_literal: true

# ActiveRecord wrapper around the pure LotLedger::Fifo and LotLedger::Purification
# logic. Reads buy/sell/stock_dividend transactions, recomputes FIFO lots and
# closures, and generates the purification (تطهير) list.
#
#   LotLedger.rebuild!(portfolio_id, asset_id)             # after any buy/sell edit
#   LotLedger.generate_purifications!(portfolio_id)        # manual "close quarter"
module LotLedger
  LEDGER_TYPE_KEYS = %w[buy sell stock_dividend].freeze

  module_function

  # Recompute lots + closures for one (portfolio, asset) from its transactions.
  # Idempotent. Preserves purification_entries (they hang off persistent lots).
  def rebuild!(portfolio_id, asset_id)
    ActiveRecord::Base.transaction(requires_new: true) do
      txns = PortfolioTransaction
        .where(portfolio_id: portfolio_id, asset_id: asset_id)
        .joins(:transaction_type)
        .where(transaction_types: { key: LEDGER_TYPE_KEYS })
        .order(:date, :id)
        .to_a

      result = Fifo.compute(txns.map { |t| event_for(t) })
      tx_by_id = txns.index_by(&:id)

      keep = []
      result[:lots].each do |lot|
        tx = tx_by_id[lot.buy_id]
        rec = AssetLot.find_or_initialize_by(buy_transaction_id: lot.buy_id)
        rec.assign_attributes(
          portfolio_id: portfolio_id,
          asset_id: asset_id,
          currency_id: tx.currency_id,
          opened_on: lot.opened_on,
          buy_price_per_unit: lot.price,
          original_quantity: lot.original_qty,
          remaining_quantity: lot.remaining_qty
        )
        rec.save!
        keep << lot.buy_id
      end

      # Drop lots whose opening transaction no longer exists (also cascades
      # their closures + purification entries).
      AssetLot.where(portfolio_id: portfolio_id, asset_id: asset_id)
              .where.not(buy_transaction_id: keep)
              .destroy_all

      lot_by_buy = AssetLot.where(portfolio_id: portfolio_id, asset_id: asset_id)
                           .index_by(&:buy_transaction_id)

      LotClosure.where(asset_lot_id: lot_by_buy.values.map(&:id)).delete_all
      result[:closures].each do |c|
        lot = lot_by_buy[c.buy_id]
        LotClosure.create!(
          asset_lot_id: lot.id,
          sell_transaction_id: c.sell_id,
          quantity: c.qty,
          opened_on: c.opened_on,
          closed_on: c.closed_on,
          buy_price_per_unit: c.buy_price,
          sell_price_per_unit: c.sell_price,
          realised_gain: c.realised_gain
        )
      end

      result[:oversells]
    end
  end

  # Generate/refresh purification entries for completed quarters. Upserts by
  # (asset_lot, quarter) so manually-entered status/amount/notes are preserved.
  def generate_purifications!(portfolio_id, asset_id = nil, today: Date.current)
    portfolio = Portfolio.find(portfolio_id)
    method = portfolio.purification_method

    lots_scope = AssetLot.where(portfolio_id: portfolio_id)
    lots_scope = lots_scope.where(asset_id: asset_id) if asset_id

    lots_scope.group_by(&:asset_id).each do |aid, lots|
      buy_by_lot_id = lots.index_by(&:id).transform_values(&:buy_transaction_id)
      lot_dicts = lots.map do |l|
        { buy_id: l.buy_transaction_id, opened_on: l.opened_on,
          original_qty: l.original_quantity.to_d }
      end
      closures = LotClosure.where(asset_lot_id: lots.map(&:id)).map do |c|
        { buy_id: buy_by_lot_id[c.asset_lot_id], closed_on: c.closed_on,
          qty: c.quantity.to_d }
      end

      entries = Purification.compute(
        lots: lot_dicts, closures: closures, method: method, today: today
      )

      lot_by_buy = lots.index_by(&:buy_transaction_id)
      entries.each do |e|
        lot = lot_by_buy[e.buy_id]
        rec = PurificationEntry.find_or_initialize_by(asset_lot_id: lot.id, quarter: e.quarter)
        rec.portfolio_id = portfolio_id
        rec.asset_id = aid
        rec.method = e.method
        rec.period_start = e.period_start
        rec.period_end = e.period_end
        rec.quantity = e.quantity
        rec.days = e.days
        rec.share_days = e.share_days
        rec.status ||= "pending" # keep existing status/amount/done_on/notes
        rec.save!
      end
    end
  end

  # Convert a transaction into a FIFO event. buy & stock_dividend open lots
  # (stock_dividend at zero cost); sell consumes them.
  def event_for(tx)
    key = tx.transaction_type.key
    qty = tx.quantity.to_d
    price =
      if key == "stock_dividend"
        BigDecimal("0")
      elsif tx.price_per_unit.present?
        tx.price_per_unit.to_d
      elsif qty.nonzero?
        tx.total_amount.to_d / qty
      else
        BigDecimal("0")
      end

    {
      type: key == "sell" ? :sell : :buy,
      id: tx.id,
      date: tx.date.to_date,
      qty: qty,
      price: price
    }
  end
end
