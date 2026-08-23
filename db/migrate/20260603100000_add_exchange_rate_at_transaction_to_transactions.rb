# frozen_string_literal: true

class AddExchangeRateAtTransactionToTransactions < ActiveRecord::Migration[7.2]
  def up
    add_column :transactions, :exchange_rate_at_transaction, :decimal, precision: 20, scale: 8

    # Backfill: for each transaction whose currency differs from the base currency,
    # find the closest ExchangeRate on or before the transaction date.
    base_id = Currency.where(is_base: true).pick(:id)
    return unless base_id

    PortfolioTransaction.where.not(currency_id: base_id).find_each do |tx|
      rate = ExchangeRate
        .where(currency_id: tx.currency_id, base_currency_id: base_id)
        .where("date <= ?", tx.date.to_date)
        .order(date: :desc)
        .first&.rate

      unless rate
        # Try inverse (base → asset currency) and invert it
        inv = ExchangeRate
          .where(currency_id: base_id, base_currency_id: tx.currency_id)
          .where("date <= ?", tx.date.to_date)
          .order(date: :desc)
          .first&.rate
        rate = (1.to_d / inv) if inv&.nonzero?
      end

      tx.update_column(:exchange_rate_at_transaction, rate) if rate
    end

    # For base-currency transactions, rate = 1
    PortfolioTransaction.where(currency_id: base_id)
      .update_all(exchange_rate_at_transaction: 1.to_d)
  end

  def down
    remove_column :transactions, :exchange_rate_at_transaction
  end
end
