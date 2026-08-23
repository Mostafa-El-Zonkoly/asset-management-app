# frozen_string_literal: true

class WalletsController < ApplicationController
  def index
    @wallet_assets = Asset.active.wallets.includes(:currency).order(:code)
  end
end
