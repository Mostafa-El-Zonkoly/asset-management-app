# frozen_string_literal: true

class Sector < ApplicationRecord
  include LookupRow

  has_many :specialities, dependent: :restrict_with_error
  has_many :assets, dependent: :restrict_with_error
  has_one :sector_target, dependent: :destroy
end
