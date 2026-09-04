# frozen_string_literal: true

class ManagementStyle < ApplicationRecord
  include TenantScoped
  include LookupRow

  has_many :assets, dependent: :restrict_with_error
  has_many :portfolio_management_style_targets, dependent: :restrict_with_error
end
