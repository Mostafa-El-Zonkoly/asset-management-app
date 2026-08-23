# frozen_string_literal: true

class Speciality < ApplicationRecord
  include LookupRow

  belongs_to :sector
  has_many :assets, dependent: :restrict_with_error
end
