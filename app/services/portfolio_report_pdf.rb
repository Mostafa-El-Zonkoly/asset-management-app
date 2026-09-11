# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Renders the report data (from PortfolioReportDataService) as a clean, TEXT-BASED
# (searchable/selectable, AI-readable — spec AI) PDF using Prawn. It only formats
# pre-computed values; it never recomputes accounting.
class PortfolioReportPdf
  HEADER = "1a2b45"
  MUTED = "667085"
  RED = "b42318"
  GREEN = "067647"

  def self.render(data)
    new(data).render
  end

  def initialize(data)
    @d = data
    @ccy = data[:reporting_currency]
  end

  def render
    doc = Prawn::Document.new(page_size: "A4", margin: 36)
    doc.font_families.update("Helvetica" => { normal: "Helvetica", bold: "Helvetica-Bold" })
    doc.default_leading 1

    summary_page(doc)
    sleeves_page(doc)
    holdings_section(doc)
    combined_section(doc)
    allocation_section(doc, "Sector allocation", @d[:sectors])
    allocation_section(doc, "Subsector allocation", @d[:subsectors])
    position_role_section(doc)
    cash_section(doc)
    warnings_section(doc)
    watchlist_section(doc)

    number_pages(doc)
    doc.render
  end

  private

  def money(v, dp = 2)
    return "—" if v.nil?

    format("%s %s", commas(v, dp), @ccy)
  end

  def commas(v, dp = 2)
    n = v.to_f.round(dp)
    whole, frac = format("%.#{dp}f", n).split(".")
    whole = whole.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    dp.zero? ? whole : "#{whole}.#{frac}"
  end

  def pct(v, dp = 1)
    return "N/A" if v.nil?

    sign = v.to_f.positive? ? "+" : ""
    "#{sign}#{commas(v, dp)}%"
  end

  def h1(doc, text)
    doc.move_down 6
    doc.fill_color HEADER
    doc.text text, size: 15, style: :bold
    doc.fill_color "000000"
    doc.move_down 4
  end

  def kv_grid(doc, pairs)
    rows = pairs.each_slice(2).map do |slice|
      slice.flat_map { |k, v| ["#{k}", v] } + (slice.size == 1 ? ["", ""] : [])
    end
    doc.table(rows, width: doc.bounds.width, cell_style: { borders: [], size: 9, padding: [2, 4] }) do
      columns(0).font_style = :bold
      columns(2).font_style = :bold
      columns(0).width = doc.bounds.width * 0.22
      columns(2).width = doc.bounds.width * 0.22
    end
  end

  def data_table(doc, header, rows, aligns: {}, widths: nil)
    return doc.text("None.", size: 9, color: MUTED) if rows.empty?

    table_rows = [header] + rows
    doc.table(table_rows, header: true, width: doc.bounds.width,
              cell_style: { size: 8, padding: [3, 4], borders: [:bottom], border_color: "e4e7ec" }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = "f2f4f7"
      aligns.each { |col, a| t.columns(col).align = a }
      t.column_widths = widths if widths
    end
  end

  def summary_page(doc)
    doc.fill_color HEADER
    doc.text "Portfolio Snapshot", size: 22, style: :bold
    doc.fill_color MUTED
    doc.text "Generated: #{@d[:generated_at].strftime('%-d %B %Y — %H:%M')}", size: 9
    doc.text "Prices as of: #{@d[:prices_as_of] ? @d[:prices_as_of].strftime('%-d %B %Y') : 'N/A'}", size: 9
    doc.text "Scope: #{@d[:scope] == :full ? 'Full portfolio' : 'Filtered view'}", size: 9
    doc.fill_color "000000"

    unless @d[:filters].empty?
      doc.move_down 4
      doc.text "Active filters: " + @d[:filters].map { |k, v| "#{k} = #{v}" }.join("  ·  "), size: 9, style: :bold
    end

    m = @d[:master]
    h1(doc, "Master summary")
    kv_grid(doc, [
      ["Master NAV", money(m.nav)], ["Equity market value", money(m.holdings_value)],
      ["Portfolio cash", money(m.cash)], ["Total wealth", money(m.total_wealth)],
      ["External contributions", money(m.external_contributions)], ["External withdrawals", money(m.external_withdrawals)],
      ["Net external capital", money(m.net_external)], ["Internal transfers", money(m.internal_transfers)],
      ["Net profit", money(m.net_profit)], ["Simple ROI", pct(m.simple_roi)],
      ["Realized P&L", money(m.realized_pnl)], ["Unrealized P&L", money(m.unrealized_pnl)]
    ])
    doc.move_down 4
    doc.text "Simple ROI is cash-on-cash and ignores timing. Internal portfolio-to-portfolio transfers are netted out of Master external capital.", size: 8, color: MUTED
  end

  def sleeves_page(doc)
    doc.start_new_page
    h1(doc, "Sleeve summary")
    header = ["Sleeve", "NAV", "Holdings", "Cash", "Weight", "Simple ROI", "Holdings #", "P&L (U)"]
    rows = @d[:sleeves].map do |s|
      [s[:name], money(s[:nav], 0), money(s[:holdings_value], 0), money(s[:cash], 0),
       pct(s[:weight]), pct(s[:simple_roi]), s[:holdings_count].to_s, money(s[:unrealized], 0)]
    end
    data_table(doc, header, rows, aligns: { 1 => :right, 2 => :right, 3 => :right, 4 => :right, 5 => :right, 6 => :right, 7 => :right })
  end

  def holdings_section(doc)
    doc.start_new_page
    h1(doc, "Holdings")
    header = ["Ticker", "Sleeve", "Sector", "Qty", "Base", "Temp", "Avg", "Price", "Mkt value", "Unreal %", "Weight"]
    total = @d[:equity_total]
    rows = @d[:holdings].map do |h|
      w = total.positive? ? (h[:market_value] / total * 100) : 0
      [h[:ticker], h[:portfolio], h[:sector], commas(h[:quantity], 2), commas(h[:base_qty], 2), commas(h[:temp_qty], 2),
       commas(h[:avg_cost], 2), commas(h[:current_price], 2), money(h[:market_value], 0), pct(h[:unrealised_pct]), pct(w)]
    end
    data_table(doc, header, rows, aligns: (3..10).to_h { |i| [i, :right] })
    doc.move_down 4
    doc.text "Total equity market value: #{money(total)}. Watchlist (quantity 0) holdings are excluded.", size: 8, color: MUTED
  end

  def combined_section(doc)
    h1(doc, "Combined stock exposure")
    header = ["Ticker", "Company", "Combined qty", "Combined value", "Weight", "Sleeves"]
    rows = @d[:combined_exposure].map do |c|
      [c[:ticker], c[:name], commas(c[:quantity], 2), money(c[:market_value], 0), pct(c[:weight]), c[:sleeves]]
    end
    data_table(doc, header, rows, aligns: { 2 => :right, 3 => :right, 4 => :right })
  end

  def allocation_section(doc, title, rows_data)
    h1(doc, title)
    header = ["Name", "Market value", "Weight", "Owned #"]
    rows = rows_data.map { |r| [r[:name], money(r[:market_value], 0), pct(r[:weight]), r[:count].to_s] }
    data_table(doc, header, rows, aligns: { 1 => :right, 2 => :right, 3 => :right })
  end

  def position_role_section(doc)
    pr = @d[:position_role]
    h1(doc, "Base vs Temporary")
    kv_grid(doc, [
      ["Base market value", money(pr[:base_value])], ["Temporary market value", money(pr[:temp_value])],
      ["Base %", pct(pr[:base_pct])], ["Temporary %", pct(pr[:temp_pct])]
    ])
  end

  def cash_section(doc)
    h1(doc, "Cash by portfolio")
    data_table(doc, ["Portfolio", "Cash", "NAV"],
               @d[:cash_by_portfolio].map { |c| [c[:name], money(c[:cash], 0), money(c[:nav], 0)] },
               aligns: { 1 => :right, 2 => :right })
    doc.move_down 6
    h1(doc, "Recent cash moves")
    rows = @d[:recent_flows].map do |f|
      cp = f.transfer? ? f.counterparty_portfolio&.name : f.related_wallet&.code
      [f.occurred_at.strftime("%Y-%m-%d"), f.portfolio.name, f.kind_label, cp.to_s, money(f.amount.to_d, 2)]
    end
    data_table(doc, ["Date", "Portfolio", "Kind", "Counterparty", "Amount"], rows, aligns: { 4 => :right })
    doc.move_down 3
    doc.text "Portfolio-to-portfolio transfers do not change Master external capital.", size: 8, color: MUTED
  end

  def warnings_section(doc)
    h1(doc, "Concentration warnings")
    if @d[:warnings].empty?
      doc.text "No concentration warnings from current exposures.", size: 9, color: GREEN
      return
    end
    rows = @d[:warnings].map { |w| [w[:level].capitalize, w[:scope], w[:name], pct(w[:weight]), w[:note]] }
    data_table(doc, ["Level", "Scope", "Name", "Weight", "Note"], rows, aligns: { 3 => :right })
  end

  def watchlist_section(doc)
    return if @d[:watchlist].empty?

    h1(doc, "Watchlist (not owned)")
    rows = @d[:watchlist].map { |w| [w[:ticker], w[:name], w[:sector], w[:subsector]] }
    data_table(doc, ["Ticker", "Company", "Sector", "Subsector"], rows)
  end

  def number_pages(doc)
    doc.number_pages "Page <page> of <total>",
                     at: [doc.bounds.right - 120, -18], size: 8, color: MUTED, width: 120, align: :right
  end
end
