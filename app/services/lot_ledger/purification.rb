# frozen_string_literal: true

require "bigdecimal"
require "date"

module LotLedger
  # Pure purification (تطهير) segmentation. No Rails dependency.
  #
  # For each lot it walks the share-count timeline (original qty, reduced by its
  # closures at their close dates) and produces purification line items:
  #   - aaoifi: one per COMPLETED calendar quarter the lot held shares in,
  #             day-weighted (share_days = Σ qty*days).
  #   - sp:     one per lot spanning its whole holding period ("one pluck").
  #
  # Day convention: [start, end) — inclusive of the open date, exclusive of the
  # close date. Only quarters whose end has passed (relative to `today`) are
  # emitted; the current quarter is still accruing.
  module Purification
    Entry = Struct.new(
      :buy_id, :method, :quarter, :period_start, :period_end,
      :quantity, :days, :share_days,
      keyword_init: true
    )

    module_function

    # lots:     [{ buy_id:, opened_on: Date, original_qty: BigDecimal }]
    # closures: [{ buy_id:, closed_on: Date, qty: BigDecimal }]
    # method:   "aaoifi" | "sp"
    # today:    Date (defaults to Date.today)
    def compute(lots:, closures:, method:, today: Date.today)
      by_lot = closures.group_by { |c| c[:buy_id] }
      lots.flat_map do |lot|
        intervals = quantity_intervals(lot, by_lot[lot[:buy_id]] || [], today)
        if method.to_s == "sp"
          sp_entry(lot, intervals, today)
        else
          aaoifi_entries(lot, intervals, today)
        end
      end.compact
    end

    # Piecewise-constant [start, end, qty] segments (end exclusive).
    def quantity_intervals(lot, lot_closures, today)
      intervals = []
      cursor = lot[:opened_on]
      qty = bd(lot[:original_qty])
      lot_closures.sort_by { |c| c[:closed_on] }.each do |c|
        intervals << [cursor, c[:closed_on], qty] if c[:closed_on] > cursor && qty.positive?
        qty -= bd(c[:qty])
        cursor = c[:closed_on]
      end
      intervals << [cursor, today, qty] if qty.positive? && today > cursor
      intervals
    end

    def aaoifi_entries(lot, intervals, today)
      entries = []
      each_quarter_through_current(lot[:opened_on], today) do |label, qstart, qend_excl|
        days = 0
        sd = BigDecimal("0")
        opening_qty = nil
        last_oe = nil
        intervals.each do |s, e, q|
          os = [s, qstart].max
          oe = [e, qend_excl].min
          next unless oe > os

          d = (oe - os).to_i
          days += d
          sd += q * d
          opening_qty ||= q
          last_oe = last_oe ? [last_oe, oe].max : oe
        end
        next if sd <= 0

        # period_end = last day shares were actually held in this quarter. For a
        # completed, fully-held quarter this is the quarter's last day; for the
        # current (in-progress) quarter it is today-1; for a lot sold mid-quarter
        # it is the day before the close. (Day convention is [start, end).)
        end_excl = [qend_excl, last_oe].min

        entries << Entry.new(
          buy_id: lot[:buy_id], method: "aaoifi", quarter: label,
          period_start: [lot[:opened_on], qstart].max,
          period_end: (end_excl - 1),
          quantity: opening_qty, days: days, share_days: sd
        )
      end
      entries
    end

    def sp_entry(lot, intervals, _today)
      return nil if intervals.empty?

      days = 0
      sd = BigDecimal("0")
      intervals.each do |s, e, q|
        d = (e - s).to_i
        days += d
        sd += q * d
      end
      return nil if sd <= 0

      Entry.new(
        buy_id: lot[:buy_id], method: "sp", quarter: "ALL",
        period_start: intervals.first[0],
        period_end: (intervals.last[1] - 1),
        quantity: bd(lot[:original_qty]), days: days, share_days: sd
      )
    end

    # Yields [label, quarter_start, quarter_end_exclusive] for every quarter from
    # the open date through the CURRENT (in-progress) quarter — so the user sees a
    # line for the running quarter too and can set its amount/status manually. The
    # share-days for the current quarter accrue only up to `today` (the intervals
    # never extend past it), and re-running refreshes them.
    def each_quarter_through_current(from_date, today)
      year = from_date.year
      qi = (from_date.month - 1) / 3
      loop do
        qstart = Date.new(year, qi * 3 + 1, 1)
        qend_excl = qi == 3 ? Date.new(year + 1, 1, 1) : Date.new(year, (qi + 1) * 3 + 1, 1)
        break if qstart > today # future quarter — nothing held yet

        yield "#{year}-Q#{qi + 1}", qstart, qend_excl
        break if qend_excl > today # this was the current in-progress quarter; stop

        if qi == 3
          qi = 0
          year += 1
        else
          qi += 1
        end
      end
    end

    def bd(value)
      return value if value.is_a?(BigDecimal)

      BigDecimal(value.to_s)
    end
  end
end
