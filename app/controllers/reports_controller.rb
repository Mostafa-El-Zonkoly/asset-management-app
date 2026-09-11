# frozen_string_literal: true

# Exports the portfolio snapshot PDF (spec U–AL). Consumes PortfolioReportDataService
# (the single accounting source of truth) and renders a text-based PDF, then stores
# a lightweight snapshot for later comparison.
class ReportsController < ApplicationController
  def portfolio
    scope = params[:scope].to_s == "filtered" ? :filtered : :full
    portfolio = resolve_portfolio(scope)
    role = %w[all base temporary].include?(params[:position_role].to_s) ? params[:position_role].to_s : "all"

    data = PortfolioReportDataService.call(scope: scope, portfolio: portfolio, position_role: role)
    save_snapshot(data)

    pdf = PortfolioReportPdf.render(data)
    send_data pdf, filename: filename_for(portfolio, data[:generated_at]),
                   type: "application/pdf", disposition: "attachment"
  end

  private

  def resolve_portfolio(scope)
    return nil unless scope == :filtered
    return nil if params[:portfolio_id].blank?

    current_user.portfolios.find_by(id: params[:portfolio_id])
  end

  def filename_for(portfolio, at)
    stamp = at.strftime("%Y-%m-%d_%H-%M")
    prefix = portfolio ? "#{portfolio.name.parameterize(separator: '_')}_snapshot" : "portfolio_snapshot"
    "#{prefix}_#{stamp}.pdf"
  end

  def save_snapshot(data)
    m = data[:master]
    payload = {
      reporting_currency: data[:reporting_currency],
      master: { nav: m.nav.to_s, cash: m.cash.to_s, equity: m.holdings_value.to_s,
                external_contributions: m.external_contributions.to_s, external_withdrawals: m.external_withdrawals.to_s,
                internal_transfers: m.internal_transfers.to_s, simple_roi: m.simple_roi&.to_s },
      sleeves: data[:sleeves].map { |s| { name: s[:name], nav: s[:nav].to_s, cash: s[:cash].to_s, weight: s[:weight].to_s, simple_roi: s[:simple_roi]&.to_s } },
      sectors: data[:sectors].map { |s| { name: s[:name], weight: s[:weight].to_s } },
      subsectors: data[:subsectors].map { |s| { name: s[:name], weight: s[:weight].to_s } },
      position_role: { base_value: data[:position_role][:base_value].to_s, temp_value: data[:position_role][:temp_value].to_s,
                       temp_pct: data[:position_role][:temp_pct]&.to_s }
    }
    PortfolioReportSnapshot.create!(generated_at: data[:generated_at], scope: data[:scope].to_s,
                                    master_nav: m.nav, payload: payload)
  rescue StandardError => e
    Rails.logger.warn("[report_snapshot] #{e.class}: #{e.message}")
  end
end
