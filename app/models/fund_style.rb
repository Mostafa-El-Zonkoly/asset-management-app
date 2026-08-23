# frozen_string_literal: true

class FundStyle < ApplicationRecord
  include LookupRow

  has_many :assets, dependent: :restrict_with_error
end
