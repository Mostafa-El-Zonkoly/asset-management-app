# frozen_string_literal: true

# Purification is being redesigned (per-quarter AAOIFI rows + S&P on sale, with
# per-row paid flags — see docs/lot_tracking_and_purification.md). The old
# entries used a different shape (manual amount + pending/done status), so they
# are cleared and regenerated from the lot ledger:
#
#   bin/rails lot_ledger:purify
#
# (the Purification screen also regenerates missing rows on first visit).
#
# Raw SQL on purpose: independent of the model, which changes in the next
# migration. Irreversible data loss by design — down is a no-op so later
# migrations can still be rolled back.
class DeleteAllPurificationEntries < ActiveRecord::Migration[7.2]
  def up
    execute "DELETE FROM purification_entries"
  end

  def down
    # Deleted rows cannot be restored.
  end
end
