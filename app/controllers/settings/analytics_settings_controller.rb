# frozen_string_literal: true

module Settings
  class AnalyticsSettingsController < ApplicationController
    before_action :set_record

    def edit; end

    def update
      if @setting.update(record_params)
        redirect_to edit_settings_analytics_setting_path, notice: "Analytics settings saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_record
      @setting = AnalyticsSetting.record
    end

    def record_params
      params.require(:analytics_setting).permit(:risk_free_rate_pct)
    end
  end
end
