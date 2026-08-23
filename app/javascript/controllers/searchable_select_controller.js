import { Controller } from "@hotwired/stimulus"

// Filters a native <select> by matching option text (e.g. "CODE — Name") as the user types.
export default class extends Controller {
  static targets = ["filter", "select"]

  connect() {
    this.syncFromSelect()
  }

  filter() {
    const query = this.filterTarget.value.trim().toLowerCase()
    Array.from(this.selectTarget.options).forEach((option) => {
      if (!option.value) {
        option.hidden = false
        return
      }

      const text = option.text.toLowerCase()
      option.hidden = query.length > 0 && !text.includes(query)
    })
  }

  syncFromSelect() {
    const selected = this.selectTarget.selectedOptions[0]
    if (!selected || !selected.value) {
      return
    }

    this.filterTarget.value = selected.text
  }
}
