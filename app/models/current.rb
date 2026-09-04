# frozen_string_literal: true

# Per-request context. Set in ApplicationController; used by TenantScoped to
# scope reads and assign ownership on writes.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end
