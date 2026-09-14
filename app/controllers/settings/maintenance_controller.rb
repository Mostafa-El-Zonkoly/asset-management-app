# frozen_string_literal: true

module Settings
  # Destructive maintenance actions (each behind its own button + confirmation):
  #   * clone the first user's settings template into this account
  #   * reset portfolio initial money (opening capital)
  #   * reset money additions/changes (contributions/withdrawals/transfers)
  class MaintenanceController < ApplicationController
    def show
      @portfolio_count = current_user.portfolios.count
      @asset_count = Asset.where(user_id: current_user.id).count
      @opening_count = PortfolioOpeningCapital.where(user_id: current_user.id).count
      @cash_flow_count = PortfolioCashFlow.where(user_id: current_user.id).count
      @is_template_user = User.order(:id).first&.id == current_user.id
    end

    # Clear this user's settings and clone the first user's template.
    def clone_settings_template
      SettingsTemplateService.clone_from_first_user!(current_user)
      redirect_to settings_maintenance_path, notice: "Settings cleared and cloned from the template account."
    rescue SettingsTemplateService::Error => e
      redirect_to settings_maintenance_path, alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_maintenance_path, alert: "Clone failed: #{e.message}"
    end

    # Reset portfolio initial money (opening-capital baselines only).
    def reset_opening_capital
      n = PortfolioOpeningCapital.where(user_id: current_user.id).delete_all
      redirect_to settings_maintenance_path, notice: "Reset opening capital for #{n} portfolio(s)."
    end

    # Reset money additions/changes (all contributions, withdrawals and transfers).
    def reset_cash_flows
      n = PortfolioCashFlow.where(user_id: current_user.id).delete_all
      redirect_to settings_maintenance_path, notice: "Removed #{n} cash move(s) (contributions, withdrawals and transfers)."
    end
  end
end
