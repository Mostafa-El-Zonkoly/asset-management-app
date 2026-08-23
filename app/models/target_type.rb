# frozen_string_literal: true

class TargetType < ApplicationRecord
  include LookupRow

  has_many :portfolio_targets, dependent: :restrict_with_error
end
