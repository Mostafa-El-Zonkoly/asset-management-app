# frozen_string_literal: true

module Settings
  class CoreScoringSettingsController < ApplicationController
    before_action :set_record

    def edit; end

    def update
      if @setting.update(record_params)
        redirect_to edit_settings_core_scoring_setting_path, notice: "Core scoring settings saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_record
      @setting = CoreScoringSetting.record
    end

    def record_params
      params.require(:core_scoring_setting).permit(
        *CoreScoringSetting::WEIGHT_FIELDS,
        *CoreScoringSetting::THRESHOLD_FIELDS,
        :ma_period_days
      )
    end
  end
end
