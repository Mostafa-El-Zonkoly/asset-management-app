import { Controller } from "@hotwired/stimulus"

// Multi-portfolio normalized (base 100) comparison chart. Fetches the
// performance_series endpoint and draws one line per portfolio. Range buttons
// reload; role + selected portfolio ids come from data values.
const COLORS = [
  "#2563eb", "#059669", "#d97706", "#dc2626", "#7c3aed",
  "#0891b2", "#db2777", "#65a30d", "#475569", "#ea580c",
]

export default class extends Controller {
  static targets = ["canvas", "rangeButton", "empty"]
  static values = { url: String, role: String, portfolioIds: String, range: String }

  connect() {
    this.chart = null
    this.range = this.rangeValue || "3m"
    this.highlight(this.range)
    this.load()
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }

  setRange(event) {
    this.range = event.currentTarget.dataset.range
    this.highlight(this.range)
    this.load()
  }

  highlight(range) {
    if (!this.hasRangeButtonTarget) return
    this.rangeButtonTargets.forEach((btn) => {
      const active = btn.dataset.range === range
      btn.classList.toggle("bg-blue-600", active)
      btn.classList.toggle("text-white", active)
      btn.classList.toggle("bg-slate-100", !active)
      btn.classList.toggle("text-slate-700", !active)
    })
  }

  buildUrl() {
    const u = new URL(this.urlValue, window.location.origin)
    u.searchParams.set("range", this.range)
    if (this.roleValue) u.searchParams.set("role", this.roleValue)
    if (this.portfolioIdsValue) u.searchParams.set("portfolio_ids", this.portfolioIdsValue)
    return u.toString()
  }

  async load() {
    let series = []
    try {
      const res = await fetch(this.buildUrl(), { headers: { Accept: "application/json" } })
      series = await res.json()
    } catch {
      series = []
    }

    const hasData = Array.isArray(series) && series.some((s) => s.points && s.points.length > 1)
    if (this.hasEmptyTarget) this.emptyTarget.hidden = hasData
    if (!hasData) {
      if (this.chart) { this.chart.destroy(); this.chart = null }
      return
    }

    // Union of all dates as labels; map each series onto them.
    const dateSet = new Set()
    series.forEach((s) => s.points.forEach((p) => dateSet.add(p[0])))
    const labels = Array.from(dateSet).sort()

    const datasets = series.map((s, i) => {
      const map = new Map(s.points)
      return {
        label: s.label,
        data: labels.map((d) => (map.has(d) ? map.get(d) : null)),
        borderColor: COLORS[i % COLORS.length],
        backgroundColor: COLORS[i % COLORS.length],
        tension: 0.2,
        spanGaps: true,
        fill: false,
        pointRadius: 0,
        borderWidth: 2,
      }
    })

    if (this.chart) this.chart.destroy()
    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "line",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        plugins: { legend: { position: "bottom" } },
        scales: {
          x: { ticks: { maxTicksLimit: 8 } },
          y: { title: { display: true, text: "Indexed (start = 100)" } },
        },
      },
    })
  }
}
