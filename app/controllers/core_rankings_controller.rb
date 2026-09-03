# frozen_string_literal: true

# The "Core Add ranking": every Core-candidate stock scored and ordered so you
# can pick where to add next (then exclude technically-extended names yourself).
class CoreRankingsController < ApplicationController
  def index
    @portfolios = current_user.portfolios.order(:name)
    owned = @portfolios.ids
    raw = params[:portfolio_ids]
    raw = raw.to_s.split(",") if raw.is_a?(String)
    @selected_portfolio_ids = Array(raw).map(&:to_i).uniq & owned
    @include_watchlist = params[:watchlist].to_s != "0"
    @cfg = CoreScoringSetting.record
    @reporting_currency = Currency.base.first
    @rows = CoreAddScoreService.rank(
      portfolio_ids: @selected_portfolio_ids.presence,
      include_watchlist: @include_watchlist
    )
  end

  # Inline edit of an asset's manual scores from the ranking table.
  def update_scores
    @asset = Asset.find(params[:asset_id])
    if @asset.update(score_params)
      redirect_to core_rankings_path(filter_params), notice: "Scores updated for #{@asset.code}."
    else
      redirect_to core_rankings_path(filter_params),
        alert: @asset.errors.full_messages.to_sentence.presence || "Could not update scores."
    end
  end

  private

  def score_params
    params.require(:asset).permit(
      :entry_score, :quality_score, :catalyst_score,
      :sharia_score_override, :catalyst_note, :core_candidate
    )
  end

  def filter_params
    fp = {}
    fp[:portfolio_ids] = params[:portfolio_ids] if params[:portfolio_ids].present?
    fp[:watchlist] = params[:watchlist] if params[:watchlist].present?
    fp
  end
end
