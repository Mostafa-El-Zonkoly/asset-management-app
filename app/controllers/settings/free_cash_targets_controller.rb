# frozen_string_literal: true

module Settings
  class FreeCashTargetsController < ApplicationController
    before_action :set_record

    def edit
    end

    def update
      if @free_cash_target.update(record_params)
        redirect_to edit_settings_free_cash_target_path, notice: "Free cash target saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_record
      @free_cash_target = FreeCashTarget.record
    end

    def record_params
      params.require(:free_cash_target).permit(:target_percentage)
    end
  end
end
