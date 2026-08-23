import { Controller } from "@hotwired/stimulus"

// Multiplies quantity × price_per_unit into total_amount.
// Recalculates whenever quantity or price changes, unless the user
// has manually edited the total themselves.
export default class extends Controller {
  static targets = ["quantity", "price", "total"]

  connect() {
    // A pre-filled total (e.g. on the edit form) is NOT treated as a manual
    // override — changing quantity or price should still recalculate it.
    // Only an in-session edit to the total field counts as manual.
    this.totalManuallyEdited = false
  }

  totalEdited() {
    this.totalManuallyEdited = this.totalTarget.value.trim() !== ""
  }

  recalculate() {
    if (this.totalManuallyEdited) return
    this.compute()
  }

  compute() {
    if (!this.hasQuantityTarget || !this.hasPriceTarget || !this.hasTotalTarget) return

    const qty = parseFloat(this.quantityTarget.value)
    const price = parseFloat(this.priceTarget.value)

    if (Number.isNaN(qty) || Number.isNaN(price)) return

    const total = qty * price
    // Trim floating-point noise while keeping precision for fractional prices.
    this.totalTarget.value = parseFloat(total.toFixed(8))
  }
}
