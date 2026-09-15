# frozen_string_literal: true

# Turn market_indices into first-class, fetchable benchmarks WITHOUT a new model
# layer (per the request: "fetching the EGX30 etc will be the same as assets").
#
#   * is_benchmark  — this index is an official market benchmark shown by the
#                     Portfolio Performance "Show benchmarks" toggle (EGX30, EGX33
#                     Shariah). Distinguished from a plain index a fund tracks.
#   * is_active     — include this index in the daily price-fetch sweep.
#   * source        — data provider key, e.g. "mubasher".
#   * fetch_code    — the provider's index handle used to BUILD the fetch URL
#                     (e.g. "egx30", "SHARIAH" → .../markets/EGX/indices/egx30/).
#                     Kept separate from `code` (the display symbol, e.g. EGX30).
#   * source_identifier — optional full fetch URL that OVERRIDES the built one
#                     (for a non-standard provider path).
#   * index_kind    — "price" (published price index) or "total_return", so the UI
#                     can label whether the series includes dividends (spec #15).
#
# All nullable/defaulted so existing rows (funds' tracked indices) keep working.
class AddBenchmarkFieldsToMarketIndices < ActiveRecord::Migration[7.2]
  def change
    change_table :market_indices, bulk: true do |t|
      t.boolean :is_benchmark, default: false, null: false
      t.boolean :is_active,    default: true,  null: false
      t.string  :source
      t.string  :fetch_code
      t.string  :source_identifier
      t.string  :index_kind, default: "price", null: false
    end

    add_index :market_indices, :is_benchmark
  end
end
