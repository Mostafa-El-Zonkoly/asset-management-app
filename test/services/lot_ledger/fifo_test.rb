# frozen_string_literal: true

require "test_helper"

# Pure unit tests for the Position-Role-aware FIFO matcher. No DB / seed needed:
# LotLedger::Fifo.compute operates on plain event hashes and returns structs.
class LotLedger::FifoTest < ActiveSupport::TestCase
  def buy(id, qty, price, role: nil, date: Date.new(2026, 1, id))
    { type: :buy, id: id, date: date, qty: qty, price: price, position_role: role }
  end

  def sell(id, qty, price, sell_from: nil, lot: nil, date: Date.new(2026, 6, id))
    { type: :sell, id: id, date: date, qty: qty, price: price,
      sell_from: sell_from, sell_lot_buy_id: lot }
  end

  def remaining_by_role(result)
    result[:lots].each_with_object(Hash.new(0.to_d)) do |l, h|
      h[l.position_role] += l.remaining_qty
    end
  end

  # --- A: buy base opens a base lot -------------------------------------------
  test "A: an explicit base buy opens one base lot" do
    r = LotLedger::Fifo.compute([buy(1, 100, 10, role: "base")])
    assert_equal 1, r[:lots].size
    assert_equal "base", r[:lots].first.position_role
    assert_equal BigDecimal("100"), r[:lots].first.remaining_qty
  end

  # --- B: buy temporary opens a temporary lot ---------------------------------
  test "B: a temporary buy opens one temporary lot" do
    r = LotLedger::Fifo.compute([buy(1, 40, 12, role: "temporary")])
    assert_equal "temporary", r[:lots].first.position_role
    assert_equal BigDecimal("40"), r[:lots].first.remaining_qty
  end

  # --- C: sell temporary_first crosses from temp into base --------------------
  test "C: temporary_first consumes all temp then dips into base" do
    events = [
      buy(1, 80, 10, role: "base"),
      buy(2, 40, 12, role: "temporary"),
      sell(3, 60, 15, sell_from: "temporary_first")
    ]
    r = LotLedger::Fifo.compute(events)
    rem = remaining_by_role(r)
    # 60 sold: 40 temp fully consumed, then 20 from base -> base 60 left, temp 0
    assert_equal BigDecimal("60"), rem["base"]
    assert_equal BigDecimal("0"), rem["temporary"]
    assert_empty r[:oversells]
    # closures must be tagged with the role they consumed
    temp_closed = r[:closures].select { |c| c.position_role == "temporary" }.sum(&:qty)
    base_closed = r[:closures].select { |c| c.position_role == "base" }.sum(&:qty)
    assert_equal BigDecimal("40"), temp_closed
    assert_equal BigDecimal("20"), base_closed
  end

  # --- D: sell temporary only touches temp lots -------------------------------
  test "D: sell_from temporary never reduces base" do
    events = [
      buy(1, 80, 10, role: "base"),
      buy(2, 40, 12, role: "temporary"),
      sell(3, 30, 15, sell_from: "temporary")
    ]
    rem = remaining_by_role(LotLedger::Fifo.compute(events))
    assert_equal BigDecimal("80"), rem["base"]
    assert_equal BigDecimal("10"), rem["temporary"]
  end

  # --- E: sell base only touches base lots ------------------------------------
  test "E: sell_from base never reduces temporary" do
    events = [
      buy(1, 80, 10, role: "base"),
      buy(2, 40, 12, role: "temporary"),
      sell(3, 30, 15, sell_from: "base")
    ]
    rem = remaining_by_role(LotLedger::Fifo.compute(events))
    assert_equal BigDecimal("50"), rem["base"]
    assert_equal BigDecimal("40"), rem["temporary"]
  end

  # --- F: specific_lot targets the named lot first ----------------------------
  test "F: specific_lot consumes the named base lot before FIFO order" do
    events = [
      buy(1, 50, 10, role: "base"),
      buy(2, 50, 11, role: "base"),
      buy(3, 40, 12, role: "temporary"),
      sell(4, 30, 15, sell_from: "specific_lot", lot: 2)
    ]
    r = LotLedger::Fifo.compute(events)
    lot2 = r[:lots].find { |l| l.buy_id == 2 }
    assert_equal BigDecimal("20"), lot2.remaining_qty, "named lot consumed first"
    # untouched lots stay whole
    assert_equal BigDecimal("50"), r[:lots].find { |l| l.buy_id == 1 }.remaining_qty
    assert_equal BigDecimal("40"), r[:lots].find { |l| l.buy_id == 3 }.remaining_qty
  end

  # --- G: defaults — missing role => base, missing sell_from => temporary_first
  test "G: nil role defaults to base and nil sell_from defaults to temporary_first" do
    events = [
      buy(1, 100, 10),                 # no role -> base
      buy(2, 20, 12, role: "temporary"),
      sell(3, 30, 15)                  # no sell_from -> temporary_first
    ]
    r = LotLedger::Fifo.compute(events)
    assert_equal "base", r[:lots].find { |l| l.buy_id == 1 }.position_role
    rem = remaining_by_role(r)
    # 30 sold: 20 temp + 10 base -> base 90, temp 0
    assert_equal BigDecimal("90"), rem["base"]
    assert_equal BigDecimal("0"), rem["temporary"]
  end

  # --- H: oversell is reported, never negative --------------------------------
  test "H: selling more than held records an oversell for the shortfall" do
    events = [
      buy(1, 30, 10, role: "base"),
      sell(2, 50, 15, sell_from: "temporary_first")
    ]
    r = LotLedger::Fifo.compute(events)
    assert_equal 1, r[:oversells].size
    assert_equal BigDecimal("20"), r[:oversells].first[:qty]
    assert_equal BigDecimal("0"), remaining_by_role(r)["base"]
  end

  # --- Reconciliation: base + temp remaining == total remaining ---------------
  test "reconciliation: per-role remaining always sums to total remaining" do
    events = [
      buy(1, 80, 10, role: "base"),
      buy(2, 40, 12, role: "temporary"),
      buy(3, 25, 11, role: "base"),
      sell(4, 15, 15, sell_from: "temporary"),
      sell(5, 30, 16, sell_from: "temporary_first")
    ]
    r = LotLedger::Fifo.compute(events)
    total = r[:lots].sum(&:remaining_qty)
    rem = remaining_by_role(r)
    assert_equal total, rem["base"] + rem["temporary"]
    # 145 bought - 45 sold = 100 remaining, no oversell
    assert_equal BigDecimal("100"), total
    assert_empty r[:oversells]
  end

  # --- Independence: temporary FIFO is independent of base FIFO ----------------
  test "temporary_first never converts a base lot into temporary" do
    events = [
      buy(1, 50, 10, role: "base"),
      buy(2, 50, 12, role: "temporary"),
      sell(3, 70, 15, sell_from: "temporary_first")
    ]
    r = LotLedger::Fifo.compute(events)
    # every remaining/closed lot keeps its original role
    assert(r[:lots].all? { |l| %w[base temporary].include?(l.position_role) })
    base_lot = r[:lots].find { |l| l.buy_id == 1 }
    assert_equal "base", base_lot.position_role
    assert_equal BigDecimal("30"), base_lot.remaining_qty # 20 of base consumed
  end
end
