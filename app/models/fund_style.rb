# frozen_string_literal: true

class FundStyle < ApplicationRecord
  include TenantScoped
  include LookupRow

  has_many :assets, dependent: :restrict_with_error
end
