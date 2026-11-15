# frozen_string_literal: true

module Settings
  # Write-only management of the EFG API credentials. There is intentionally no
  # action that returns the stored Trading ID or API key. Only
  # EfgCredential::OWNER_EMAIL may reach this controller; everyone else gets 404.
  class EfgCredentialsController < ApplicationController
    before_action :require_owner!
    after_action :no_store

    def edit
      @credential = EfgCredential.current
    end

    def update
      attrs = params.require(:efg_credential).permit(:trading_id, :api_key, :company_code)
      EfgCredential.store!(
        trading_id: attrs[:trading_id],
        api_key: attrs[:api_key],
        company_code: attrs[:company_code],
        by: current_user
      )
      redirect_to edit_settings_efg_credential_path, notice: "EFG credentials saved. Use “Test connection” to verify them."
    rescue ActiveRecord::RecordInvalid => e
      @credential = EfgCredential.current
      flash.now[:alert] = e.record.errors.full_messages.to_sentence.presence || "Could not save credentials."
      render :edit, status: :unprocessable_entity
    end

    def destroy
      EfgCredential.clear!(by: current_user)
      redirect_to edit_settings_efg_credential_path, notice: "EFG credentials removed. Stock prices will be fetched from Mubasher."
    end

    def test
      credential = EfgCredential.current
      return redirect_to(edit_settings_efg_credential_path, alert: "No EFG credentials are set.") unless credential

      EfgCredential.client.authenticate!
      credential.update_column(:last_verified_at, Time.current)
      redirect_to edit_settings_efg_credential_path, notice: "Connected to EFG successfully."
    rescue Efg::FetchError => e
      redirect_to edit_settings_efg_credential_path, alert: "EFG connection failed: #{e.message}"
    end

    private

    def require_owner!
      raise ActionController::RoutingError, "Not Found" unless EfgCredential.manageable_by?(current_user)
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
