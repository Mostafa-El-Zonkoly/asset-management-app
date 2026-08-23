# frozen_string_literal: true

module Api
  class AssetsController < ApplicationController
    def compare
      asset_a = Asset.find(params.require(:asset_a_id))
      asset_b = Asset.find(params.require(:asset_b_id))
      key = ChartRangeHelper.range_key_from_params(
        range: params[:range].presence,
        from: params[:from],
        to: params[:to]
      )
      alignment = params[:alignment].presence_in(AssetCompareService::ALIGNMENTS) || "auto"
      render json: AssetCompareService.payload(asset_a, asset_b, key, alignment: alignment)
    end

    def prices
      asset = Asset.find(params[:id])
      data = AssetStatsService.price_series(asset, range_key: params[:range] || "3m")
      render json: data
    end

    def index_prices
      asset = Asset.find(params[:id])
      data = AssetStatsService.index_series(asset, range_key: params[:range] || "3m")
      render json: data
    end
  end
end
