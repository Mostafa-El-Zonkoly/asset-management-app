import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.tbody = this.element.tBodies[0]
    this.thead = this.element.tHead
    this.sortIndex = null
    this.sortDirection = "asc"
    if (!this.tbody || !this.thead || this.thead.rows.length === 0) return

    this.decorateHeaders()
  }

  decorateHeaders() {
    const headers = Array.from(this.thead.rows[0].cells)
    headers.forEach((th, index) => {
      const label = th.textContent.trim()
      if (!label || th.dataset.sortable === "false") return

      th.classList.add("select-none")

      const button = document.createElement("button")
      button.type = "button"
      button.className = "inline-flex items-center gap-1 font-semibold text-slate-600 hover:text-slate-900"
      button.innerHTML = `${this.escapeHtml(label)} <span data-sort-arrow>↕</span>`
      button.addEventListener("click", () => this.sortBy(index))

      th.textContent = ""
      th.appendChild(button)
    })
  }

  sortBy(index) {
    this.sortDirection = this.sortIndex === index && this.sortDirection === "asc" ? "desc" : "asc"
    this.sortIndex = index

    const rows = Array.from(this.tbody.rows)
    const sortableRows = rows.filter((row) => !this.pinnedRow(row))
    const pinnedRows = rows.filter((row) => this.pinnedRow(row))

    sortableRows.sort((a, b) => {
      const result = this.compareValues(this.cellSortValue(a, index), this.cellSortValue(b, index))
      return this.sortDirection === "asc" ? result : -result
    })

    ;[...sortableRows, ...pinnedRows].forEach((row) => this.tbody.appendChild(row))
    this.refreshArrows()
  }

  refreshArrows() {
    const headers = Array.from(this.thead.rows[0].cells)
    headers.forEach((th, idx) => {
      const arrow = th.querySelector("[data-sort-arrow]")
      if (!arrow) return
      if (idx !== this.sortIndex) {
        arrow.textContent = "↕"
      } else {
        arrow.textContent = this.sortDirection === "asc" ? "↑" : "↓"
      }
    })
  }

  pinnedRow(row) {
    if (row.dataset.sortable === "false") return true
    return Array.from(row.cells).some((cell) => Number(cell.colSpan) > 1)
  }

  cellSortValue(row, index) {
    const cell = row.cells[index]
    if (!cell) return ""
    return (cell.dataset.sortValue || cell.textContent || "").trim()
  }

  compareValues(left, right) {
    const n1 = this.numberValue(left)
    const n2 = this.numberValue(right)
    if (n1 !== null && n2 !== null) return n1 - n2

    const d1 = this.dateValue(left)
    const d2 = this.dateValue(right)
    if (d1 !== null && d2 !== null) return d1 - d2

    return left.localeCompare(right, undefined, { numeric: true, sensitivity: "base" })
  }

  numberValue(raw) {
    const normalized = raw.replace(/[%,$£€\s]/g, "").replace(/,/g, "")
    if (!/^-?\d+(\.\d+)?$/.test(normalized)) return null
    return Number(normalized)
  }

  dateValue(raw) {
    const ts = Date.parse(raw)
    return Number.isNaN(ts) ? null : ts
  }

  escapeHtml(text) {
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
  }
};
