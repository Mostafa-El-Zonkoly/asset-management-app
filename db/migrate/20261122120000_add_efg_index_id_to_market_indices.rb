class AddEfgIndexIdToMarketIndices < ActiveRecord::Migration[7.2]
  def change
    add_column :market_indices, :efg_index_id, :integer
  end
end
