# frozen_string_literal: true

module LookupRow
  extend ActiveSupport::Concern

  included do
    validates :key, presence: true, uniqueness: true
    validates :label, presence: true
    validates :position, numericality: { only_integer: true }

    scope :active, -> { where(active: true) }
  end

  def self.[](key)
    find_by(key: key.to_s)
  end
end
