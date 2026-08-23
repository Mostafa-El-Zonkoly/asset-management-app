# frozen_string_literal: true

class WalletLedgerService
  InsufficientFundsError = Class.new(StandardError)

  class << self
    def balance(wallet_asset)
      wid = wallet_asset.id
      PortfolioTransaction.includes(:transaction_type).where(
        "transactions.asset_id = :id OR transactions.related_wallet_id = :id OR transactions.transfer_to_wallet_id = :id",
        id: wid
      ).sum { |t| effect_on_wallet(t, wid) }
    end

    def effect_on_wallet(transaction, wallet_id)
      key = transaction.transaction_type.key
      case key
      when "deposit"
        transaction.asset_id == wallet_id ? transaction.total_amount : 0.to_d
      when "withdrawal"
        transaction.asset_id == wallet_id ? -transaction.total_amount : 0.to_d
      when "buy"
        transaction.related_wallet_id == wallet_id ? -transaction.total_amount : 0.to_d
      when "sell", "cash_dividend"
        transaction.related_wallet_id == wallet_id ? transaction.total_amount : 0.to_d
      when "transfer"
        if transaction.asset_id == wallet_id && transaction.transfer_to_wallet_id.present?
          -transaction.total_amount
        elsif transaction.asset_id == wallet_id && transaction.related_wallet_id.present?
          transaction.total_amount
        else
          0.to_d
        end
      else
        0.to_d
      end
    end

    def transactions_touching_wallet(wallet_id)
      PortfolioTransaction.includes(:transaction_type).where(
        "transactions.asset_id = :id OR transactions.related_wallet_id = :id OR transactions.transfer_to_wallet_id = :id",
        id: wallet_id
      )
    end

    # Ledger balance for +wallet_id+ after swapping out +tx_before+ for hypothetical +merged_row+ overrides.
    def balance_after_substituting_for(wallet_id, tx_before, merged_attrs)
      wid = wallet_id.to_i
      virtual = VirtualTransaction.stub(tx_before, merged_attrs)
      txs = transactions_touching_wallet(wid).where.not(id: tx_before.id)
      txs.sum { |t| effect_on_wallet(t, wid) } + effect_on_wallet(virtual, wid)
    end

    # Wallets to validate when replacing +tx_before+ with edits in +merged_row+.
    def wallet_ids_balance_check_for_substitution(tx_before, merged_row)
      merged_row = merged_row.stringify_keys
      key = tx_before.transaction_type.key
      old = tx_before.attributes
      new_attrs = old.merge(merged_row)
      wallets = []

      case key
      when "deposit", "withdrawal"
        wallets |= [ old["asset_id"], new_attrs["asset_id"] ]
      when "buy", "sell", "cash_dividend"
        wallets |= [ old["related_wallet_id"], new_attrs["related_wallet_id"] ]
      else
        return []
      end

      wallets.compact.map(&:to_i).uniq
    end

    def assert_non_negative_balances_after_substitution!(tx_before, merged_row)
      wallet_ids_balance_check_for_substitution(tx_before, merged_row).each do |wid|
        bal = balance_after_substituting_for(wid, tx_before, merged_row)
        raise InsufficientFundsError if bal < 0
      end
    end
  end

  # Minimal stand-in for ledger math (not persisted).
  class VirtualTransaction
    def self.stub(tx_before, merged_row_overrides)
      merged = tx_before.attributes.merge(stringify_keys(merged_row_overrides))
      inst = PortfolioTransaction.instantiate(merged)
      inst.transaction_type = tx_before.transaction_type
      inst.readonly!
      inst
    end

    def self.stringify_keys(attrs)
      return {} if attrs.blank?

      attrs.to_h.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end
end
