# frozen_string_literal: true

# The provider's index handle used to BUILD the fetch URL
# (.../markets/EGX/indices/<fetch_code>/), kept separate from `code` (the display
# symbol, e.g. EGX30). Added in its own migration — the benchmark-fields migration
# had already run in some environments, so this guarantees the column lands there
# too. Guarded so it is safe if a fresh DB somehow already has it.
class AddFetchCodeToMarketIndices < ActiveRecord::Migration[7.2]
  def change
    add_column :market_indices, :fetch_code, :string unless column_exists?(:market_indices, :fetch_code)
  end
end
