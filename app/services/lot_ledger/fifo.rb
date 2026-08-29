# frozen_string_literal: true

require "bigdecimal"
require "date"

module LotLedger
  # Pure FIFO matching. No Rails / ActiveRecord dependency so it can be unit
  # tested in isolation. Buys (and stock dividends, passed as zero-price buys)
  # open lots; sells consume the oldest open lots first.
  #
  # events: array of hashes, each:
  #   { type: :buy | :sell, id:, date: Date, qty: BigDecimal, price: BigDecimal }
  #
  # returns:
  #   { lots: [Lot], closures: [Closure], oversells: [{ sell_id:, qty: }] }
  module Fifo
    Lot = Struct.new(
      :buy_id, :opened_on, :price, :original_qty, :remaining_qty,
      keyword_init: true
    )

    Closure = Struct.new(
      :buy_id, :sell_id, :qty, :opened_on, :closed_on,
      :buy_price, :sell_price, :realised_gain,
      keyword_init: true
    )

    module_function

    def compute(events)
      lots = []
      closures = []
      oversells = []
      open_queue = []

      sorted(events).each do |e|
        if e[:type] == :buy
          lot = Lot.new(
            buy_id: e[:id],
            opened_on: e[:date],
            price: bd(e[:price]),
            original_qty: bd(e[:qty]),
            remaining_qty: bd(e[:qty])
          )
          lots << lot
          open_queue << lot if lot.remaining_qty.positive?
        else
          remaining = bd(e[:qty])
          while remaining.positive? && open_queue.any?
            lot = open_queue.first
            take = [lot.remaining_qty, remaining].min
            closures << Closure.new(
              buy_id: lot.buy_id,
              sell_id: e[:id],
              qty: take,
              opened_on: lot.opened_on,
              closed_on: e[:date],
              buy_price: lot.price,
              sell_price: bd(e[:price]),
              realised_gain: (bd(e[:price]) - lot.price) * take
            )
            lot.remaining_qty -= take
            remaining -= take
            open_queue.shift unless lot.remaining_qty.positive?
          end
          oversells << { sell_id: e[:id], qty: remaining } if remaining.positive?
        end
      end

      { lots: lots, closures: closures, oversells: oversells }
    end

    def sorted(events)
      events.sort_by { |e| [e[:date], e[:id].to_i] }
    end

    def bd(value)
      return value if value.is_a?(BigDecimal)

      BigDecimal(value.to_s)
    end
  end
end
