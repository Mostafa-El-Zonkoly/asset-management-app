# frozen_string_literal: true

# Aggregates purification rows into total / paid / outstanding figures, split by
# AAOIFI and S&P. Amounts are kept per currency (a portfolio can hold assets in
# several currencies and they are not summed across).
#
#   PurificationStats.summarize(entries)   # => [Summary, ...] one per currency
#   PurificationStats.for_asset(asset)     # => { summary:, quarters: [...] }
module PurificationStats
  ZERO = BigDecimal("0")

  Summary = Struct.new(
    :currency, :aaoifi_total, :aaoifi_paid, :sp_total, :sp_paid, keyword_init: true
  ) do
    def aaoifi_outstanding = aaoifi_total - aaoifi_paid
    def sp_outstanding     = sp_total - sp_paid
    def total              = aaoifi_total + sp_total
    def paid               = aaoifi_paid + sp_paid
    def outstanding        = total - paid
  end

  module_function

  # entries must have asset_lot: :currency preloaded.
  def summarize(entries)
    entries.group_by { |e| currency_code(e) }.sort.map do |code, rows|
      Summary.new(
        currency: code,
        aaoifi_total: sum(rows) { |e| e.aaoifi_amount },
        aaoifi_paid:  sum(rows.select(&:aaoifi_paid)) { |e| e.aaoifi_amount },
        sp_total:     sum(rows) { |e| e.sp_amount },
        sp_paid:      sum(rows.select(&:sp_paid)) { |e| e.sp_amount }
      )
    end
  end

  # Per-asset view for the asset details/listing: lifetime summary plus one line
  # per quarter (with the rates used, newest first).
  def for_asset(asset)
    entries = PurificationEntry.where(asset_id: asset.id).includes(asset_lot: :currency).to_a
    rates = PurificationRate.where(asset_id: asset.id).index_by(&:quarter)
    quarters = (entries.map(&:quarter) | rates.keys).sort.reverse.map do |q|
      rows = entries.select { |e| e.quarter == q }
      {
        quarter: q,
        rate: rates[q],
        summary: summarize(rows).first,
        entries: rows.size,
        unpaid_entries: rows.count { |e| (e.aaoifi_amount.positive? && !e.aaoifi_paid) || (e.sp_amount.positive? && !e.sp_paid) }
      }
    end
    { summary: summarize(entries).first, quarters: quarters }
  end

  def currency_code(entry)
    entry.asset_lot&.currency&.code || "—"
  end

  def sum(rows)
    rows.inject(ZERO) { |acc, e| acc + yield(e).to_d }
  end
end
