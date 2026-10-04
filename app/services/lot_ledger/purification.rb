# frozen_string_literal: true

require "bigdecimal"
require "date"

module LotLedger
  # Pure purification (تطهير) row generation. No Rails dependency.
  #
  # Mirrors the reference spreadsheet: one ROW per parcel of shares held during a
  # calendar quarter. A lot that is bought once and sold in pieces produces:
  #
  #   * one CLOSED row per sale that hit it in that quarter (qty x days held up
  #     to that sale), and
  #   * one ONGOING row for whatever is still held at quarter end, which is
  #     carried into the next quarter (and only the ongoing part is carried).
  #
  # Buy 100, sell 40 -> a closed row of 40 and an ongoing row of 60.
  # Buy 100, buy 150, sell 200 (FIFO) -> lot 1 is closed (100); lot 2 splits into
  # a closed 100 and an ongoing 50.
  #
  # Each row carries two independent purification amounts:
  #   * AAOIFI = quantity x days x per-day rate (every quarter the parcel is held)
  #   * S&P    = (sell - buy) x quantity x percentage — ONLY on the closed row,
  #              only when the sale made a profit.
  #
  # Day convention matches the spreadsheet: BOTH ends inclusive, i.e.
  # 1 + (min(sell date, quarter end) - max(buy date, quarter start)). Ongoing
  # rows run to the quarter end (also what the spreadsheet does), so the running
  # quarter is a projection that is recomputed as soon as a sale is recorded.
  module Purification
    # per_day:       AAOIFI purification per share per day
    # sp_percentage: S&P purification as a PERCENT of profit (4.25 == 4.25%)
    Rate = Struct.new(:per_day, :sp_percentage, keyword_init: true)

    Row = Struct.new(
      :buy_id, :sell_id, :quarter, :period_start, :period_end,
      :quantity, :days, :buy_price, :sell_price,
      :aaoifi_rate, :aaoifi_amount, :sp_rate, :sp_amount,
      keyword_init: true
    ) do
      def closed?
        !sell_id.nil?
      end

      def ongoing?
        !closed?
      end
    end

    QUARTER_LABEL = /\A(\d{4})-Q([1-4])\z/

    module_function

    # lots:     [{ buy_id:, opened_on: Date, original_qty:, buy_price: }]
    # closures: [{ buy_id:, sell_id:, closed_on: Date, qty:, buy_price:, sell_price: }]
    # rates:    { "2026-Q3" => Rate } for ONE asset (missing quarter => zero rates)
    # today:    Date — quarters after the one containing `today` are not generated
    def compute(lots:, closures:, rates: {}, today: Date.today)
      by_lot = closures.group_by { |c| c[:buy_id] }
      lots.flat_map do |lot|
        sorted = (by_lot[lot[:buy_id]] || []).sort_by { |c| [c[:closed_on], c[:sell_id].to_i] }
        lot_rows(lot, sorted, rates, today)
      end
    end

    def lot_rows(lot, closures, rates, today)
      rows = []
      original = bd(lot[:original_qty])

      quarters(lot[:opened_on], today).each do |label, qstart, qend|
        held = original - sum_qty(closures.select { |c| c[:closed_on] < qstart })
        next unless held.positive?

        held_start = [lot[:opened_on], qstart].max
        rate = rates[label]
        in_quarter = closures.select { |c| c[:closed_on] >= qstart && c[:closed_on] <= qend }

        in_quarter.each do |c|
          rows << closed_row(lot, c, label, held_start, rate)
        end

        remaining = held - sum_qty(in_quarter)
        rows << ongoing_row(lot, label, held_start, qend, remaining, rate) if remaining.positive?
      end
      rows
    end

    def closed_row(lot, closure, label, held_start, rate)
      qty = bd(closure[:qty])
      days = inclusive_days(held_start, closure[:closed_on])
      buy = bd(closure[:buy_price] || lot[:buy_price])
      sell = bd(closure[:sell_price])
      sp_rate = rate ? bd(rate.sp_percentage) : BigDecimal("0")
      profit = (sell - buy) * qty

      Row.new(
        buy_id: lot[:buy_id], sell_id: closure[:sell_id], quarter: label,
        period_start: held_start, period_end: closure[:closed_on],
        quantity: qty, days: days, buy_price: buy, sell_price: sell,
        aaoifi_rate: per_day(rate), aaoifi_amount: qty * days * per_day(rate),
        sp_rate: sp_rate, sp_amount: profit.positive? ? profit * sp_rate / 100 : BigDecimal("0")
      )
    end

    def ongoing_row(lot, label, held_start, qend, qty, rate)
      days = inclusive_days(held_start, qend)
      Row.new(
        buy_id: lot[:buy_id], sell_id: nil, quarter: label,
        period_start: held_start, period_end: qend,
        quantity: qty, days: days, buy_price: bd(lot[:buy_price]), sell_price: nil,
        aaoifi_rate: per_day(rate), aaoifi_amount: qty * days * per_day(rate),
        sp_rate: rate ? bd(rate.sp_percentage) : BigDecimal("0"), sp_amount: BigDecimal("0")
      )
    end

    # [[label, quarter_start, quarter_end_inclusive], ...] from the quarter of
    # `from_date` through the quarter containing `today`.
    def quarters(from_date, today)
      out = []
      cursor = quarter_bounds(quarter_label(from_date)).first
      while cursor <= today
        label = quarter_label(cursor)
        qstart, qend = quarter_bounds(label)
        out << [label, qstart, qend]
        cursor = qend + 1
      end
      out
    end

    def quarter_label(date)
      "#{date.year}-Q#{(date.month - 1) / 3 + 1}"
    end

    # => [first_day, last_day] of the calendar quarter named by `label`.
    def quarter_bounds(label)
      m = QUARTER_LABEL.match(label.to_s) or raise ArgumentError, "bad quarter #{label.inspect}"
      start = Date.new(m[1].to_i, (m[2].to_i - 1) * 3 + 1, 1)
      [start, (start >> 3) - 1]
    end

    def valid_quarter?(label)
      QUARTER_LABEL.match?(label.to_s)
    end

    def inclusive_days(from, to)
      (to - from).to_i + 1
    end

    def per_day(rate)
      rate ? bd(rate.per_day) : BigDecimal("0")
    end

    def sum_qty(list)
      list.inject(BigDecimal("0")) { |acc, c| acc + bd(c[:qty]) }
    end

    def bd(value)
      return value if value.is_a?(BigDecimal)

      BigDecimal(value.to_s)
    end
  end
end
