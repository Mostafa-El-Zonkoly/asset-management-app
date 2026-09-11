# frozen_string_literal: true

# Migration baseline (spec AO). One page to set each portfolio's opening external
# capital, opening cash and migration date. Historical transactions are never
# rewritten; from the migration date forward, explicit cash moves take over.
class OpeningCapitalsController < ApplicationController
  def edit
    @portfolios = current_user.portfolios.order(:name)
    @by_portfolio = PortfolioOpeningCapital.where(portfolio_id: @portfolios.ids).index_by(&:portfolio_id)
  end

  def update
    base_id = Currency.reporting_currency_id
    (params[:openings] || {}).each do |portfolio_id, attrs|
      pid = portfolio_id.to_i
      next unless current_user.portfolios.exists?(id: pid)
      next if attrs[:opening_capital].blank? && attrs[:opening_cash].blank? && attrs[:migration_on].blank?

      rec = PortfolioOpeningCapital.find_or_initialize_by(portfolio_id: pid)
      rec.assign_attributes(
        opening_capital: attrs[:opening_capital].presence || 0,
        opening_cash: attrs[:opening_cash].presence || 0,
        migration_on: attrs[:migration_on].presence || Date.current,
        currency_id: base_id
      )
      rec.save!
    end
    redirect_to edit_opening_capitals_path, notice: "Opening capital saved."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to edit_opening_capitals_path, alert: e.message
  end
end
