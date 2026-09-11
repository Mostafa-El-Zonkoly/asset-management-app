# frozen_string_literal: true

require "test_helper"

# Pure aggregation tests for the report data (spec tests 10 combined exposure + AC
# concentration). Holdings rows are passed directly to the private aggregators.
class PortfolioReportDataServiceTest < ActiveSupport::TestCase
  def svc
    PortfolioReportDataService.allocate.tap do |s|
      s.instance_variable_set(:@role, "all")
    end
  end

  def bd(x) = BigDecimal(x.to_s)

  def holding(ticker, portfolio, mv, sector: "Financials", subsector: "Banks")
    { ticker: ticker, name: "#{ticker} Co", portfolio: portfolio, sector: sector, subsector: subsector,
      quantity: bd(1), base_qty: bd(1), temp_qty: bd(0), market_value: bd(mv),
      base_value: bd(mv), temp_value: bd(0) }
  end

  # TEST 10 — same stock across sleeves aggregates into one combined exposure
  test "combined exposure aggregates a stock across sleeves" do
    holdings = [holding("ETEL", "Core", 100), holding("ETEL", "Borsa Halal", 50), holding("COMI", "Core", 50)]
    total = bd(200)
    combined = svc.send(:combined_exposure, holdings, total)
    etel = combined.find { |c| c[:ticker] == "ETEL" }
    assert_equal bd(150), etel[:market_value]
    assert_equal "Borsa Halal, Core", etel[:sleeves]
    assert_equal bd(75), etel[:weight] # 150/200*100
  end

  test "concentration warnings only fire from calculated exposures" do
    # ETEL 40% of equity -> severe stock; sector 40% -> severe sector
    holdings = [holding("ETEL", "Core", 40), holding("COMI", "Core", 60, sector: "Industrials", subsector: "Materials")]
    total = bd(100)
    warns = svc.send(:concentration_warnings, holdings, total)
    stock = warns.find { |w| w[:scope] == "Stock" && w[:name] == "ETEL" }
    assert_equal "severe", stock[:level], "ETEL at 40% exceeds the 15% stock maximum"
    assert warns.any? { |w| w[:scope] == "Sector" && w[:level] == "severe" }, "a sector above 30% is severe"
  end

  test "allocation excludes nothing passed but weights sum to 100" do
    holdings = [holding("A", "Core", 30, sector: "Tech"), holding("B", "Core", 70, sector: "Banks")]
    alloc = svc.send(:allocation, holdings, :sector, bd(100))
    assert_in_delta 100.0, alloc.sum { |r| r[:weight].to_f }, 0.001
  end
end
