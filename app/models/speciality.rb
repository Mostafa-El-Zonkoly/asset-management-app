# frozen_string_literal: true

class Speciality < ApplicationRecord
  include TenantScoped
  tenant_through :sector
  include LookupRow

  belongs_to :sector
  has_many :assets, dependent: :restrict_with_error
end
