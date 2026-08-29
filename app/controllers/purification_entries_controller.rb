# frozen_string_literal: true

# The "list to purify" (تطهير) screen. The app produces the segmented list from
# the FIFO lot ledger; the amount to purify is entered manually here and the
# status is tracked as a checklist (pending / done / not_required).
class PurificationEntriesController < ApplicationController
  before_action :set_entry, only: :update

  def index
    @portfolios = current_user.portfolios.order(:name)
    portfolio_ids = @portfolios.ids

    @selected_portfolio_id = params[:portfolio_id].presence
    @selected_status = params[:status].presence

    scope = PurificationEntry
      .where(portfolio_id: portfolio_ids)
      .includes(:asset, :portfolio, asset_lot: :currency)
      .chronological

    scope = scope.where(portfolio_id: @selected_portfolio_id) if @selected_portfolio_id
    scope = scope.where(status: @selected_status) if @selected_status.in?(PurificationEntry::STATUSES)

    @entries = scope.to_a
    @grouped = @entries
      .group_by(&:portfolio)
      .transform_values { |es| es.group_by(&:asset) }

    @summary = {
      pending:      @entries.count { |e| e.status == "pending" },
      done:         @entries.count { |e| e.status == "done" },
      not_required: @entries.count { |e| e.status == "not_required" },
      amount_done:  @entries.select { |e| e.status == "done" }.sum { |e| e.amount.to_d }
    }
  end

  def update
    if @entry.update(entry_params)
      redirect_to purification_entries_path(filter_params), notice: "Purification entry updated."
    else
      redirect_to purification_entries_path(filter_params),
        alert: @entry.errors.full_messages.to_sentence.presence || "Could not update entry."
    end
  end

  # Regenerate/refresh the purification list from the current lot ledger.
  # Upserts by (lot, quarter) so manually-entered status/amount/notes survive.
  def generate
    portfolios =
      if params[:portfolio_id].present?
        current_user.portfolios.where(id: params[:portfolio_id]).to_a
      else
        current_user.portfolios.to_a
      end

    ids = portfolios.map(&:id)
    before = PurificationEntry.where(portfolio_id: ids).count
    portfolios.each { |p| LotLedger.generate_purifications!(p.id) }
    added = PurificationEntry.where(portfolio_id: ids).count - before

    label = portfolios.one? ? portfolios.first.name : "all portfolios"
    added_msg =
      if added.positive?
        "#{added} new #{'entry'.pluralize(added)} added."
      else
        "No new entries."
      end

    redirect_to purification_entries_path(filter_params),
      notice: "Purification list refreshed for #{label}. #{added_msg}"
  end

  private

  def set_entry
    @entry = PurificationEntry
      .joins(:portfolio)
      .where(portfolios: { user_id: current_user.id })
      .find(params[:id])
  end

  def entry_params
    params.require(:purification_entry).permit(:status, :amount, :done_on, :notes)
  end

  def filter_params
    params.permit(:portfolio_id, :status).to_h.symbolize_keys.reject { |_, v| v.blank? }
  end
end
