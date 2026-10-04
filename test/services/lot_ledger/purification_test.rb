# frozen_string_literal: true

require "test_helper"

# Pure unit tests for the quarterly purification row generator. No DB: it works
# on plain hashes and returns structs. Golden values come from the reference
# spreadsheet ("Stocks 6-9 2026.xlsx", Transactions tab).
class LotLedger::PurificationTest < ActiveSupport::TestCase
  P = LotLedger::Purification

  def bd(v) = BigDecimal(v.to_s)

  def lot(id, date, qty, price)
    { buy_id: id, opened_on: date, original_qty: bd(qty), buy_price: bd(price) }
  end

  def closure(buy_id, sell_id, date, qty, buy_price, sell_price)
    { buy_id: buy_id, sell_id: sell_id, closed_on: date, qty: bd(qty),
      buy_price: bd(buy_price), sell_price: bd(sell_price) }
  end

  def rate(per_day, sp_percentage)
    P::Rate.new(per_day: bd(per_day), sp_percentage: bd(sp_percentage))
  end

  def rows(lots:, closures: [], rates: {}, today:)
    P.compute(lots: lots, closures: closures, rates: rates, today: today)
  end

  # --- golden rows from the spreadsheet ------------------------------------------

  test "closed row matches the spreadsheet: loss => AAOIFI only, no S&P" do
    r = rows(
      lots: [lot(1, Date.new(2026, 7, 29), 140, "27.34")],
      closures: [closure(1, 10, Date.new(2026, 9, 17), 140, "27.34", "27.14")],
      rates: { "2026-Q3" => rate("0.0006", "0.57") },
      today: Date.new(2026, 9, 20)
    ).sole
    assert r.closed?
    assert_equal 51, r.days # 29 Jul .. 17 Sep, both ends inclusive
    assert_equal bd("4.284"), r.aaoifi_amount
    assert_equal 0, r.sp_amount
  end

  test "closed row matches the spreadsheet: profit => AAOIFI plus S&P on the profit" do
    r = rows(
      lots: [lot(1, Date.new(2026, 7, 29), 135, "91.27")],
      closures: [closure(1, 10, Date.new(2026, 9, 17), 135, "91.27", "94.7")],
      rates: { "2026-Q3" => rate("0.016", "16.69") },
      today: Date.new(2026, 9, 20)
    ).sole
    assert_equal bd("110.16"), r.aaoifi_amount
    assert_equal bd("77.283045"), r.sp_amount # (94.7 - 91.27) * 135 * 16.69%
  end

  test "bought and sold on the same day counts as one day" do
    r = rows(
      lots: [lot(1, Date.new(2026, 9, 1), 5, "784.07")],
      closures: [closure(1, 10, Date.new(2026, 9, 1), 5, "784.07", "834.88")],
      rates: { "2026-Q3" => rate("0.063", "0.72") },
      today: Date.new(2026, 9, 20)
    ).sole
    assert_equal 1, r.days
    assert_equal bd("0.315"), r.aaoifi_amount
    assert_equal bd("1.82916"), r.sp_amount
  end

  # --- splitting -----------------------------------------------------------------

  test "ongoing lot: one row running to the quarter end" do
    r = rows(
      lots: [lot(1, Date.new(2026, 9, 1), 190, "32.35")],
      rates: { "2026-Q3" => rate("0.03", "0.88") },
      today: Date.new(2026, 9, 20)
    ).sole
    assert r.ongoing?
    assert_equal Date.new(2026, 9, 30), r.period_end
    assert_equal 30, r.days
    assert_equal bd(190 * 30) * bd("0.03"), r.aaoifi_amount
    assert_equal 0, r.sp_amount
  end

  test "buy 100, sell 40 splits into a closed 40 and an ongoing 60" do
    r = rows(
      lots: [lot(1, Date.new(2026, 8, 1), 100, 10)],
      closures: [closure(1, 10, Date.new(2026, 8, 20), 40, 10, 12)],
      rates: { "2026-Q3" => rate("0.01", "10") },
      today: Date.new(2026, 8, 25)
    )
    closed  = r.find(&:closed?)
    ongoing = r.find(&:ongoing?)
    assert_equal 2, r.size
    assert_equal 40, closed.quantity
    assert_equal 20, closed.days                  # 1 Aug .. 20 Aug
    assert_equal bd("8"), closed.aaoifi_amount    # 40 x 20 x 0.01
    assert_equal bd("8"), closed.sp_amount        # (12-10) x 40 x 10%
    assert_equal 60, ongoing.quantity
    assert_equal 61, ongoing.days                 # 1 Aug .. 30 Sep
    assert_equal bd("36.6"), ongoing.aaoifi_amount
    assert_equal 0, ongoing.sp_amount
  end

  test "buy 100, buy 150, sell 200 (FIFO): lot 1 closed, lot 2 split 100 closed / 50 ongoing" do
    events = [
      { type: :buy,  id: 1, date: Date.new(2026, 8, 1),  qty: 100, price: 10 },
      { type: :buy,  id: 2, date: Date.new(2026, 8, 5),  qty: 150, price: 11 },
      { type: :sell, id: 3, date: Date.new(2026, 8, 20), qty: 200, price: 13 }
    ]
    fifo = LotLedger::Fifo.compute(events)
    lots = fifo[:lots].map { |l| lot(l.buy_id, l.opened_on, l.original_qty, l.price) }
    closures = fifo[:closures].map { |c| closure(c.buy_id, c.sell_id, c.closed_on, c.qty, c.buy_price, c.sell_price) }

    r = rows(lots: lots, closures: closures, today: Date.new(2026, 8, 25))
    by_lot = r.group_by(&:buy_id)

    assert_equal [[100, true]], by_lot[1].map { |x| [x.quantity, x.closed?] }
    assert_equal [[100, true], [50, false]], by_lot[2].sort_by { |x| x.closed? ? 0 : 1 }.map { |x| [x.quantity, x.closed?] }
  end

  test "two sales in one quarter each get their own closed row, held to their own sale date" do
    r = rows(
      lots: [lot(1, Date.new(2026, 8, 1), 100, 10)],
      closures: [closure(1, 10, Date.new(2026, 8, 11), 30, 10, 11), closure(1, 11, Date.new(2026, 8, 21), 20, 10, 9)],
      rates: { "2026-Q3" => rate("0.01", "10") },
      today: Date.new(2026, 8, 25)
    )
    closed = r.select(&:closed?).sort_by(&:days)
    assert_equal [11, 21], closed.map(&:days)
    assert_equal [30, 20], closed.map { |c| c.quantity.to_i }
    assert_equal bd("3"), closed[0].sp_amount     # profit 30 x 1 x 10%
    assert_equal 0, closed[1].sp_amount           # sold at a loss
    assert_equal 50, r.find(&:ongoing?).quantity
  end

  # --- quarters ------------------------------------------------------------------

  test "only the ongoing part carries over; S&P is charged only in the sale quarter" do
    lots = [lot(1, Date.new(2026, 5, 10), 100, 10)]
    closures = [closure(1, 10, Date.new(2026, 8, 15), 40, 10, 15)]
    rates = {
      "2026-Q2" => rate("0.01", "5"), "2026-Q3" => rate("0.02", "5"), "2026-Q4" => rate("0.03", "5")
    }
    r = rows(lots: lots, closures: closures, rates: rates, today: Date.new(2026, 11, 3))

    assert_equal %w[2026-Q2 2026-Q3 2026-Q3 2026-Q4], r.map(&:quarter).sort_by { |q| q }

    q2 = r.select { |x| x.quarter == "2026-Q2" }.sole
    assert_equal 100, q2.quantity                      # not split before the sale
    assert q2.ongoing?
    assert_equal 52, q2.days                           # 10 May .. 30 Jun

    q3_closed = r.find { |x| x.quarter == "2026-Q3" && x.closed? }
    q3_open   = r.find { |x| x.quarter == "2026-Q3" && x.ongoing? }
    assert_equal 40, q3_closed.quantity
    assert_equal 46, q3_closed.days                    # 1 Jul .. 15 Aug (quarter start, not buy date)
    assert_equal bd("40") * 5 * bd("0.05"), q3_closed.sp_amount # (15-10) x 40 x 5%
    assert_equal 60, q3_open.quantity
    assert_equal 92, q3_open.days

    q4 = r.select { |x| x.quarter == "2026-Q4" }.sole
    assert_equal 60, q4.quantity
    assert q4.ongoing?
    assert_equal 0, q4.sp_amount
    assert_equal bd(60 * 92) * bd("0.03"), q4.aaoifi_amount
  end

  test "a fully closed lot produces no rows after its sale quarter" do
    r = rows(
      lots: [lot(1, Date.new(2026, 1, 5), 10, 10)],
      closures: [closure(1, 10, Date.new(2026, 2, 5), 10, 10, 11)],
      today: Date.new(2026, 11, 1)
    )
    assert_equal ["2026-Q1"], r.map(&:quarter)
    assert r.sole.closed?
  end

  test "quarters after today are not generated and missing rates give zero amounts" do
    r = rows(lots: [lot(1, Date.new(2026, 9, 1), 10, 10)], today: Date.new(2026, 9, 20))
    assert_equal ["2026-Q3"], r.map(&:quarter)
    assert_equal 0, r.sole.aaoifi_amount
  end

  test "a lot bought before today's quarter starts a new ongoing row in that quarter" do
    r = rows(lots: [lot(1, Date.new(2026, 9, 30), 10, 10)], today: Date.new(2026, 10, 2))
    assert_equal %w[2026-Q3 2026-Q4], r.map(&:quarter)
    assert_equal [1, 92], r.map(&:days)
  end

  # --- helpers -------------------------------------------------------------------

  test "quarter helpers" do
    assert_equal "2026-Q3", P.quarter_label(Date.new(2026, 9, 30))
    assert_equal "2027-Q1", P.quarter_label(Date.new(2027, 1, 1))
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 12, 31)], P.quarter_bounds("2026-Q4")
    assert P.valid_quarter?("2026-Q1")
    refute P.valid_quarter?("2026-Q5")
    assert_raises(ArgumentError) { P.quarter_bounds("nope") }
  end
end
