# frozen_string_literal: true

require "bigdecimal"
require "date"

module LotLedger
  # Pure FIFO matching, Position-Role aware. No Rails / ActiveRecord dependency
  # so it can be unit tested in isolation. Buys (and stock dividends, passed as
  # zero-price buys) open lots tagged with a position_role ("base" | "temporary").
  # Sells consume open lots according to `sell_from`, FIFO *within* each role:
  #   temporary_first (default): temporary lots first, then base lots
  #   temporary:                 temporary lots only
  #   base:                      base lots only
  #   specific_lot:              the named lot first, then temporary_first order
  # Temporary FIFO is independent of Base FIFO; a lot's role is never converted.
  #
  # events: array of hashes, each:
  #   buy:  { type: :buy, id:, date:, qty:, price:, position_role: }
  #   sell: { type: :sell, id:, date:, qty:, price:, sell_from:, sell_lot_buy_id: }
  #
  # returns: { lots: [Lot], closures: [Closure], oversells: [{ sell_id:, qty: }] }
  module Fifo
    Lot = Struct.new(
      :buy_id, :opened_on, :price, :original_qty, :remaining_qty, :position_role,
      keyword_init: true
    )

    Closure = Struct.new(
      :buy_id, :sell_id, :qty, :opened_on, :closed_on,
      :buy_price, :sell_price, :realised_gain, :position_role,
      keyword_init: true
    )

    module_function

    def compute(events)
      lots = []
      closures = []
      oversells = []

      sorted(events).each do |e|
        if e[:type] == :buy
          lots << Lot.new(
            buy_id: e[:id],
            opened_on: e[:date],
            price: bd(e[:price]),
            original_qty: bd(e[:qty]),
            remaining_qty: bd(e[:qty]),
            position_role: normalize_role(e[:position_role])
          )
        else
          remaining = bd(e[:qty])
          consumption_order(lots, e).each do |lot|
            break unless remaining.positive?
            next unless lot.remaining_qty.positive?

            take = [lot.remaining_qty, remaining].min
            closures << Closure.new(
              buy_id: lot.buy_id,
              sell_id: e[:id],
              qty: take,
              opened_on: lot.opened_on,
              closed_on: e[:date],
              buy_price: lot.price,
              sell_price: bd(e[:price]),
              realised_gain: (bd(e[:price]) - lot.price) * take,
              position_role: lot.position_role
            )
            lot.remaining_qty -= take
            remaining -= take
          end
          oversells << { sell_id: e[:id], qty: remaining } if remaining.positive?
        end
      end

      { lots: lots, closures: closures, oversells: oversells }
    end

    # Ordered list of open lots a sell should consume, honouring sell_from.
    # `lots` is already in FIFO (date, id) order, so filtering preserves FIFO.
    def consumption_order(lots, sell)
      open = lots.select { |l| l.remaining_qty.positive? }
      temp = open.select { |l| l.position_role == "temporary" }
      base = open.select { |l| l.position_role == "base" }

      case normalize_sell_from(sell[:sell_from])
      when "temporary"
        temp
      when "base"
        base
      when "specific_lot"
        target = open.find { |l| l.buy_id == sell[:sell_lot_buy_id] }
        [target].compact + (temp + base).reject { |l| l.equal?(target) }
      else # temporary_first
        temp + base
      end
    end

    def normalize_role(role)
      role.to_s == "temporary" ? "temporary" : "base"
    end

    def normalize_sell_from(sf)
      s = sf.to_s
      %w[temporary base specific_lot].include?(s) ? s : "temporary_first"
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
