# frozen_string_literal: true

# The purification (تطهير) screen. Rows are produced by LotLedger from the FIFO
# lots — one row per parcel of shares per calendar quarter (see
# LotLedger::Purification). They are listed on one tab per quarter; the user
# only enters the per-asset quarterly rates and ticks rows as paid.
class PurificationEntriesController < ApplicationController
  before_action :set_entry, only: :toggle

  def index
    @portfolios = current_user.portfolios.order(:name)
    portfolio_ids = @portfolios.ids
    @selected_portfolio_id = params[:portfolio_id].presence&.to_i
    @selected_portfolio_id = nil unless portfolio_ids.include?(@selected_portfolio_id)
    scoped_ids = @selected_portfolio_id ? [@selected_portfolio_id] : portfolio_ids

    generate_missing!(scoped_ids)

    all_entries = PurificationEntry
      .where(portfolio_id: scoped_ids)
      .includes(:asset, :portfolio, asset_lot: :currency)
      .to_a

    @current_quarter = LotLedger::Purification.quarter_label(Date.current)
    @quarters = (all_entries.map(&:quarter) | [@current_quarter]).sort.reverse
    @quarter = params[:quarter].presence_in(@quarters) || @current_quarter
    @selected_status = params[:status].presence_in(%w[unpaid paid])

    @overall = PurificationStats.summarize(all_entries)
    quarter_entries = all_entries.select { |e| e.quarter == @quarter }
    @quarter_summary = PurificationStats.summarize(quarter_entries)

    @entries = quarter_entries
    @entries = @entries.select { |e| unpaid?(e) } if @selected_status == "unpaid"
    @entries = @entries.reject { |e| unpaid?(e) } if @selected_status == "paid"
    @entries = @entries.sort_by { |e| [e.asset.code, e.period_start, e.closed? ? 1 : 0, e.id] }

    @rate_assets = quarter_entries.map(&:asset).uniq.sort_by(&:code)
    @rates = PurificationRate.where(asset_id: @rate_assets.map(&:id), quarter: @quarter).index_by(&:asset_id)
    @filter_params = filter_params
  end

  # Tick / untick one purification (AAOIFI or S&P) of one row as paid.
  def toggle
    kind = params[:kind].to_s
    return redirect_to(purification_entries_path(filter_params), alert: "Unknown purification kind.") unless kind.in?(PurificationEntry::KINDS)

    paid = !@entry.paid?(kind)
    @entry.update!("#{kind}_paid" => paid, "#{kind}_paid_on" => (paid ? Date.current : nil))
    redirect_to purification_entries_path(filter_params)
  end

  # Mark the AAOIFI / S&P / both purification of EVERY row of a quarter (within
  # the portfolio filter; the paid/unpaid view filter is ignored) as paid or
  # unpaid in one go. Rows with nothing to pay are left alone.
  def bulk_pay
    kinds = params[:kind].to_s == "both" ? PurificationEntry::KINDS : [params[:kind].to_s]
    unless kinds.all? { |k| k.in?(PurificationEntry::KINDS) } && LotLedger::Purification.valid_quarter?(params[:quarter])
      return redirect_to(purification_entries_path(filter_params), alert: "Invalid request.")
    end

    paid = params[:paid].to_s == "1"
    scope = PurificationEntry.where(portfolio_id: scoped_portfolio_ids, quarter: params[:quarter])
    scope = scope.where(asset_id: params[:asset_id]) if params[:asset_id].present?

    count = 0
    kinds.each do |k|
      count += scope.where("#{k}_amount > 0").update_all(
        "#{k}_paid": paid, "#{k}_paid_on": (paid ? Date.current : nil), updated_at: Time.current
      )
    end
    redirect_to purification_entries_path(filter_params),
      notice: "Marked #{count} #{'purification'.pluralize(count)} as #{paid ? 'paid' : 'unpaid'}."
  end

  # Save the two per-asset inputs for a quarter (AAOIFI per share per day and S&P
  # percentage) and recalculate the affected rows. A paid tick is dropped only
  # where the recalculated amount differs.
  def rates
    quarter = params[:quarter].to_s
    return redirect_to(purification_entries_path(filter_params), alert: "Invalid quarter.") unless LotLedger::Purification.valid_quarter?(quarter)

    submitted = params.fetch(:rates, {}).to_unsafe_h
    changed_asset_ids = []
    errors = []

    submitted.each do |asset_id, attrs|
      next unless attrs.respond_to?(:key?)

      asset = Asset.find_by(id: asset_id)
      next unless asset

      rate = PurificationRate.find_or_initialize_by(asset_id: asset.id, quarter: quarter)
      per_day = attrs["aaoifi_per_day"].to_s.strip
      sp_pct  = attrs["sp_percentage"].to_s.strip
      next if rate.new_record? && per_day.blank? && sp_pct.blank?

      rate.assign_attributes(
        aaoifi_per_day: per_day.presence || 0,
        sp_percentage: sp_pct.presence || 0
      )
      next unless rate.changed?

      if rate.save
        changed_asset_ids << asset.id
      else
        errors << "#{asset.code}: #{rate.errors.full_messages.to_sentence}"
      end
    end

    changed_asset_ids.each do |aid|
      AssetLot.where(asset_id: aid).distinct.pluck(:portfolio_id).each do |pid|
        LotLedger.generate_purifications!(pid, aid)
      end
    end

    if errors.any?
      redirect_to purification_entries_path(filter_params), alert: errors.to_sentence
    else
      redirect_to purification_entries_path(filter_params),
        notice: "Rates saved for #{changed_asset_ids.size} #{'asset'.pluralize(changed_asset_ids.size)} in #{quarter}."
    end
  end

  # Regenerate the rows from the current lot ledger (idempotent — paid flags are
  # preserved).
  def generate
    portfolios =
      if params[:portfolio_id].present?
        current_user.portfolios.where(id: params[:portfolio_id]).to_a
      else
        current_user.portfolios.to_a
      end

    portfolios.each { |p| LotLedger.generate_purifications!(p.id) }

    label = portfolios.one? ? portfolios.first.name : "all portfolios"
    redirect_to purification_entries_path(filter_params), notice: "Purification refreshed for #{label}."
  end

  private

  def set_entry
    @entry = PurificationEntry
      .joins(:portfolio)
      .where(portfolios: { user_id: current_user.id })
      .find(params[:id])
  end

  def scoped_portfolio_ids
    ids = current_user.portfolios.ids
    pid = params[:portfolio_id].presence&.to_i
    pid && ids.include?(pid) ? [pid] : ids
  end

  def unpaid?(entry)
    (entry.aaoifi_amount.positive? && !entry.aaoifi_paid) || (entry.sp_amount.positive? && !entry.sp_paid)
  end

  # Rows appear automatically: after the migration cleared the table, and when a
  # new quarter starts (ongoing lots roll over into it). Missing = a lot with no
  # rows at all (closed lots) or an open lot with no row in the current quarter.
  def generate_missing!(portfolio_ids)
    current_quarter = LotLedger::Purification.quarter_label(Date.current)
    stale_portfolio_ids = AssetLot
      .where(portfolio_id: portfolio_ids)
      .where("asset_lots.opened_on <= ?", Date.current)
      .where(<<~SQL.squish, current_quarter)
        NOT EXISTS (
          SELECT 1 FROM purification_entries pe
          WHERE pe.asset_lot_id = asset_lots.id
            AND (asset_lots.remaining_quantity <= 0 OR pe.quarter = ?)
        )
      SQL
      .distinct.pluck(:portfolio_id)

    stale_portfolio_ids.each { |pid| LotLedger.generate_purifications!(pid) }
  end

  def filter_params
    params.permit(:portfolio_id, :status, :quarter).to_h.symbolize_keys.reject { |_, v| v.blank? }
  end
end
