import { Controller } from "@hotwired/stimulus"

const ACTIVE_RANGE_CLASSES = ["bg-blue-600", "text-white", "hover:bg-blue-700"]
const INACTIVE_RANGE_CLASSES = ["bg-slate-100", "text-slate-700", "hover:bg-slate-200"]

export default class extends Controller {
  static targets = ["canvas", "summary", "rangeButton", "priceList"]
  static values = { url: String, valueColumnLabel: String }

  connect() {
    this.chart = null
    this.syncRangeHighlightFromUrl(this.urlValue)
    this.load(this.urlValue)
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }

  setRange(event) {
    const range = event.currentTarget.dataset.range
    const u = new URL(this.urlValue, window.location.origin)
    u.searchParams.set("range", range)
    this.load(u.toString())
  }

  syncRangeHighlightFromUrl(urlString) {
    let range = null
    try {
      range = new URL(urlString, window.location.origin).searchParams.get("range")
    } catch {
      range = null
    }
    this.highlightRange(range)
  }

  highlightRange(range) {
    if (!this.hasRangeButtonTarget) return
    this.rangeButtonTargets.forEach((btn) => {
      const active = range != null && btn.dataset.range === range
      ACTIVE_RANGE_CLASSES.forEach((c) => btn.classList.toggle(c, active))
      INACTIVE_RANGE_CLASSES.forEach((c) => btn.classList.toggle(c, !active))
      btn.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  async load(url) {
    this.urlValue = url
    this.syncRangeHighlightFromUrl(url)

    const res = await fetch(url, { headers: { Accept: "application/json" } })
    const data = await res.json()
    if (!data.length) {
      if (this.chart) this.chart.destroy()
      this.renderIntervalSummary(null)
      this.renderPriceList([])
      return
    }
    const labels = data.map((d) => d.date)
    const values = data.map((d) => d.value ?? d.price)

    if (this.chart) this.chart.destroy()

    this.renderIntervalSummary(this.computeIntervalPct(values))
    this.renderPriceList(data)

    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "line",
      data: {
        labels,
        datasets: [
          {
            label: "Value",
            data: values,
            borderColor: "rgb(59, 130, 246)",
            tension: 0.2,
            fill: false,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: { x: { ticks: { maxTicksLimit: 8 } } },
      },
    })
  }

  computeIntervalPct(values) {
    const nums = values.map(Number).filter((n) => !Number.isNaN(n))
    if (nums.length < 2) return null
    const first = nums[0]
    const last = nums[nums.length - 1]
    if (first === 0) return null
    return ((last / first) - 1) * 100
  }

  renderIntervalSummary(pct) {
    if (!this.hasSummaryTarget) return

    this.summaryTarget.replaceChildren()

    if (pct === null || Number.isNaN(pct)) {
      const p = document.createElement("p")
      p.className = "text-sm text-slate-500"
      p.textContent = "Not enough data for this range."
      this.summaryTarget.appendChild(p)
      return
    }

    const outer = document.createElement("div")
    outer.className = "flex flex-col gap-1"

    const cap = document.createElement("p")
    cap.className = "text-xs font-medium uppercase text-slate-500"
    cap.textContent = "Interval change (first → last in range)"

    const val = document.createElement("p")
    val.className =
      "text-sm font-semibold tabular-nums " +
      (pct > 0 ? "text-emerald-600" : pct < 0 ? "text-red-600" : "text-slate-600")
    const sign = pct > 0 ? "+" : ""
    val.textContent = `${sign}${pct.toFixed(2)}%`

    outer.appendChild(cap)
    outer.appendChild(val)
    this.summaryTarget.appendChild(outer)
  }

  renderPriceList(data) {
    if (!this.hasPriceListTarget) return

    this.priceListTarget.replaceChildren()

    if (!data.length) {
      const p = document.createElement("p")
      p.className = "text-sm text-slate-500"
      p.textContent = "No entries in this range."
      this.priceListTarget.appendChild(p)
      return
    }

    const label = this.valueColumnLabelValue || "Value"
    const table = document.createElement("table")
    table.className = "w-full text-left text-sm"

    const thead = document.createElement("thead")
    thead.className = "sticky top-0 bg-slate-50 text-xs uppercase text-slate-500"
    const hr = document.createElement("tr")
    ;["Date", label].forEach((text, i) => {
      const th = document.createElement("th")
      th.className = i === 0 ? "px-3 py-2" : "px-3 py-2 text-right"
      th.textContent = text
      hr.appendChild(th)
    })
    thead.appendChild(hr)

    const tbody = document.createElement("tbody")
    const rows = [...data].reverse()
    rows.forEach((d) => {
      const tr = document.createElement("tr")
      tr.className = "border-t border-slate-100"
      const tdDate = document.createElement("td")
      tdDate.className = "px-3 py-2 whitespace-nowrap"
      tdDate.textContent = this.formatListDate(d.date)
      const tdVal = document.createElement("td")
      tdVal.className = "px-3 py-2 text-right tabular-nums"
      const n = Number(d.value ?? d.price)
      tdVal.textContent = Number.isFinite(n)
        ? n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 6 })
        : "—"
      tr.appendChild(tdDate)
      tr.appendChild(tdVal)
      tbody.appendChild(tr)
    })

    table.appendChild(thead)
    table.appendChild(tbody)
    this.priceListTarget.appendChild(table)
  }

  formatListDate(iso) {
    const t = Date.parse(iso)
    if (Number.isNaN(t)) return iso
    return new Date(t).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    })
  }
}
