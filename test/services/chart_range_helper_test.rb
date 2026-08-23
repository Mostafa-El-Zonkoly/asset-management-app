# frozen_string_literal: true

require "test_helper"

class ChartRangeHelperTest < ActiveSupport::TestCase
  test "cw cm cy align to calendar boundaries" do
    travel_to Time.zone.local(2026, 4, 16, 12, 0, 0) do
      cw = ChartRangeHelper.range("cw")
      assert_equal Date.new(2026, 4, 12), cw.begin
      assert_equal Date.new(2026, 4, 16), cw.end

      cm = ChartRangeHelper.range("cm")
      assert_equal Date.new(2026, 4, 1), cm.begin
      assert_equal Date.new(2026, 4, 16), cm.end

      cy = ChartRangeHelper.range("cy")
      assert_equal Date.new(2026, 1, 1), cy.begin
      assert_equal Date.new(2026, 4, 16), cy.end
    end
  end

  test "range_key_from_params prefers explicit from and to" do
    key = ChartRangeHelper.range_key_from_params(range: "cw", from: "2026-01-10", to: "2026-01-02")
    assert_equal "2026-01-02..2026-01-10", key
  end

  test "range_key_from_params falls back to range preset" do
    key = ChartRangeHelper.range_key_from_params(range: "cy", from: "", to: "")
    assert_equal "cy", key
  end

  test "range_key_from_params defaults to 3m when range is blank" do
    key = ChartRangeHelper.range_key_from_params(range: nil, from: "", to: "")
    assert_equal "3m", key
  end
end
