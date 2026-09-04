class ApplicationController < ActionController::Base
  include Pagy::Backend

  before_action :authenticate_user!, unless: :devise_controller?
  before_action :set_current_user

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

  def set_current_user
    Current.user = current_user
  end
end
