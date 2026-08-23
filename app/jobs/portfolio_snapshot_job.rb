# frozen_string_literal: true

class PortfolioSnapshotJob < ApplicationJob
  queue_as :default

  def perform
    PortfolioSnapshotService.record_all!(as_of: Date.current)
  end
end
