# frozen_string_literal: true

class StockPurpose < ApplicationRecord
  include TenantScoped
  include LookupRow

  has_many :assets, dependent: :restrict_with_error
end
