# frozen_string_literal: true

module Settings
  class ZakaSettingsController < ApplicationController
    before_action :set_record

    def edit
      @assets = Asset.active.order(:code)
    end

    def update
      if @zaka_setting.update(record_params)
        redirect_to edit_settings_zaka_setting_path, notice: "Zakaa settings saved."
      else
        @assets = Asset.active.order(:code)
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_record
      @zaka_setting = ZakaSetting.record
    end

    def record_params
      params.require(:zaka_setting).permit(
        :nisab_asset_id,
        :nisab_quantity,
        :rate_percentage,
        :payment_interval_days
      )
    end
  end
end
