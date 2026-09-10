import { Controller } from "@hotwired/stimulus"

// Normalized (base 100) comparison chart. Curves are compounded cash-flow-adjusted
// returns (server-side), so deposits/withdrawals never move a line. Portfolios are
// solid; benchmarks dashed. Tooltip shows index, return %, value and investment P&L.
const COLORS = [
  "#2563eb", "#059669", "#d97706", "#dc2626", "#7c3aed",
  "#0891b2", "#db2777", "#65a30d", "#475569", "#ea580c",
]

export default class extends Controller {
  static targets = ["canvas", "rangeButton", "empty", "commonNote"]
  static values = {
    url: String, role: String, portfolioIds: String, range: String,
    mode: String, benchmark: Boolean,
  }

  connect() {
    this.chart = null
    this.range = this.rangeValue || "3m"
    this.mode = this.modeValue || "own"
    this.benchmark = this.benchmarkValue || false
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

  setMode(event) {
    this.mode = event.target.value
    this.load()
  }

  toggleBenchmark(event) {
    this.benchmark = event.target.checked
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
    u.searchParams.set("mode", this.mode)
    if (this.benchmark) u.searchParams.set("benchmark", "1")
    if (this.roleValue) u.searchParams.set("role", this.roleValue)
    if (this.portfolioIdsValue) u.searchParams.set("portfolio_ids", this.portfolioIdsValue)
    return u.toString()
  }

  fmt(n, digits = 2) {
    if (n === null || n === undefined) return "N/A"
    return Number(n).toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits })
  }

  async load() {
    let payload = {}
    try {
      const res = await fetch(this.buildUrl(), { headers: { Accept: "application/json" } })
      payload = await res.json()
    } catch {
      payload = {}
    }
    const series = Array.isArray(payload.series) ? payload.series : []

    if (this.hasCommonNoteTarget) {
      if (this.mode === "common" && payload.common_start) {
        this.commonNoteTarget.hidden = false
        this.commonNoteTarget.textContent = `Common start: ${payload.common_start} — all series rebased to 100 on this date.`
      } else {
        this.commonNoteTarget.hidden = true
      }
    }

    const hasData = series.some((s) => s.points && s.points.length > 1)
    if (this.hasEmptyTarget) this.emptyTarget.hidden = hasData
    if (!hasData) {
      if (this.chart) { this.chart.destroy(); this.chart = null }
      return
    }

    const dateSet = new Set()
    series.forEach((s) => s.points.forEach((p) => dateSet.add(p[0])))
    const labels = Array.from(dateSet).sort()

    // point = [iso, index, return_pct, value, pnl]. Keep full rows for the tooltip.
    const datasets = series.map((s, i) => {
      const rowByDate = new Map(s.points.map((p) => [p[0], p]))
      const isBench = s.kind === "benchmark"
      return {
        label: s.label,
        data: labels.map((d) => (rowByDate.has(d) ? rowByDate.get(d)[1] : null)),
        _rows: labels.map((d) => rowByDate.get(d) || null),
        _isBench: isBench,
        borderColor: COLORS[i % COLORS.length],
        backgroundColor: COLORS[i % COLORS.length],
        borderDash: isBench ? [6, 4] : [],
        tension: 0.2,
        spanGaps: true,
        fill: false,
        pointRadius: 0,
        borderWidth: 2,
      }
    })

    if (this.chart) this.chart.destroy()
    const fmt = this.fmt.bind(this)
    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "line",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: { position: "bottom" },
          tooltip: {
            callbacks: {
              title: (items) => (items.length ? items[0].label : ""),
              label: (ctx) => {
                const row = ctx.dataset._rows ? ctx.dataset._rows[ctx.dataIndex] : null
                if (!row) return `${ctx.dataset.label}: N/A`
                const [, index, ret, value, pnl] = row
                const sign = ret > 0 ? "+" : ""
                const parts = [
                  `Index ${fmt(index)}`,
                  `Return ${sign}${fmt(ret)}%`,
                ]
                if (!ctx.dataset._isBench) {
                  parts.push(`Value ${value === null ? "N/A" : fmt(value, 0)}`)
                  parts.push(`P&L ${pnl === null ? "N/A" : (pnl > 0 ? "+" : "") + fmt(pnl, 0)}`)
                }
                return `${ctx.dataset.label} — ${parts.join(" · ")}`
              },
            },
          },
        },
        scales: {
          x: { ticks: { maxTicksLimit: 8 } },
          y: { title: { display: true, text: "Indexed (start = 100)" } },
        },
      },
    })
  }
}
