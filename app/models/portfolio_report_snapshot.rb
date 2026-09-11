# frozen_string_literal: true

# A saved summary of the book at export time (spec AL). Payload holds master +
# per-portfolio NAV/cash, sector/subsector weights, base/temp values and the
# ROI/TWR/XIRR figures — enough for later "how did it change?" comparisons.
class PortfolioReportSnapshot < ApplicationRecord
  include TenantScoped
  validates :generated_at, presence: true
end
