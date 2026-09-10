# frozen_string_literal: true

# Position Role: distinguishes a permanent Strategic/Base position from Temporary
# additions, at the transaction/lot level. Backward compatible — existing buys and
# lots default to "base", so all pre-existing totals are unchanged.
class AddPositionRole < ActiveRecord::Migration[7.2]
  def up
    add_column :transactions, :position_role, :string        # buys: base | temporary
    add_column :transactions, :sell_from, :string            # sells: temporary_first | temporary | base | specific_lot
    add_column :transactions, :sell_from_lot_buy_id, :bigint # sells with specific_lot: the target lot's buy transaction id
    add_index  :transactions, :position_role

    # Existing BUY transactions -> base (backward compatible default).
    execute(<<~SQL)
      UPDATE transactions SET position_role = 'base'
      WHERE position_role IS NULL
        AND transaction_type_id IN (SELECT id FROM transaction_types WHERE key = 'buy')
    SQL

    unless column_exists?(:asset_lots, :position_role)
      add_column :asset_lots, :position_role, :string, null: false, default: "base"
      add_index  :asset_lots, :position_role
    end
  end

  def down
    remove_column :asset_lots, :position_role if column_exists?(:asset_lots, :position_role)
    remove_column :transactions, :position_role
    remove_column :transactions, :sell_from
    remove_column :transactions, :sell_from_lot_buy_id
  end
end
