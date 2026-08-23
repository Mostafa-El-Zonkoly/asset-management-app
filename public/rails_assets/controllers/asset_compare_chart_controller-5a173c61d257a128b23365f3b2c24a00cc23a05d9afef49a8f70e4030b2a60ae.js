import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["canvas", "form", "rangeField", "fromField", "toField", "summary"]
  static values = { url: String }

  connect() {
    this.chart = null
    if (this.hasFormTarget) this.loadFromForm()
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }

  applyPreset(event) {
    event.preventDefault()
    const range = event.currentTarget.dataset.range
    if (this.hasRangeFieldTarget) this.rangeFieldTarget.value = range
    if (this.hasFromFieldTarget) this.fromFieldTarget.value = ""
    if (this.hasToFieldTarget) this.toFieldTarget.value = ""
    if (this.hasFormTarget) this.formTarget.requestSubmit()
  }

  async loadFromForm() {
    if (!this.hasFormTarget || !this.hasCanvasTarget) return

    const fd = new FormData(this.formTarget)
    const assetA = fd.get("asset_a_id")
    const assetB = fd.get("asset_b_id")
    if (!assetA || !assetB) {
      if (this.chart) this.chart.destroy()
      this.renderIntervalSummary({
        interval_changes: [],
        empty_hint: "Select two assets to compare.",
      })
      return
    }

    const u = new URL(this.urlValue, window.location.origin)
    u.searchParams.set("asset_a_id", assetA)
    u.searchParams.set("asset_b_id", assetB)
    const range = fd.get("range") || "3m"
    const from = fd.get("from")
    const to = fd.get("to")
    const alignment = fd.get("alignment")
    if (from && to) {
      u.searchParams.set("from", from)
      u.searchParams.set("to", to)
    } else {
      u.searchParams.set("range", range)
    }
    if (alignment) u.searchParams.set("alignment", alignment)

    await this.load(u.toString())
  }

  async load(url) {
    let data
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" } })
      if (!res.ok) {
        if (this.chart) this.chart.destroy()
        this.renderIntervalSummary({
          interval_changes: [],
          empty_hint: `Could not load comparison (${res.status}). Try refreshing or signing in again.`,
        })
        return
      }
      data = await res.json()
    } catch (_err) {
      if (this.chart) this.chart.destroy()
      this.renderIntervalSummary({
        interval_changes: [],
        empty_hint: "Could not load comparison (invalid response). Check the network tab for errors.",
      })
      return
    }

    if (!data.labels?.length) {
      if (this.chart) this.chart.destroy()
      this.renderIntervalSummary(data)
      return
    }

    const raw = (data.datasets || []).slice(0, 2)
    const datasets = raw.map((ds) => ({
      label: ds.label,
      data: ds.data,
      borderColor: ds.borderColor,
      tension: 0.2,
      fill: false,
      yAxisID: "y",
    }))

    if (this.chart) this.chart.destroy()

    const boundsFor = (arrays) => {
      const nums = arrays
        .flat()
        .map((v) => (v == null ? null : Number(v)))
        .filter((v) => v != null && !Number.isNaN(v))
      if (!nums.length) return null

      const min = Math.min(...nums)
      const max = Math.max(...nums)
      const span = max - min

      const pad = span === 0 ? (Math.abs(max) || 1) * 0.1 : span * 0.1
      return { min: min - pad, max: max + pad }
    }

    const sharedBounds = boundsFor(datasets.map((ds) => ds.data))

    const scales = {
      x: { ticks: { maxTicksLimit: 10 } },
      y: {
        type: "linear",
        position: "left",
        title: {
          display: true,
          text: data.y_axis_label,
        },
        ...(sharedBounds ? { min: sharedBounds.min, max: sharedBounds.max } : {}),
      },
    }

    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "line",
      data: {
        labels: data.labels,
        datasets,
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        plugins: {
          tooltip: {
            callbacks: {
              label(ctx) {
                const v = ctx.parsed.y
                if (v == null || Number.isNaN(v)) return `${ctx.dataset.label}: —`
                return `${ctx.dataset.label}: ${v.toFixed(2)}%`
              },
            },
          },
        },
        scales,
      },
    })

    this.renderIntervalSummary(data)
  }

  renderIntervalSummary(data) {
    if (!this.hasSummaryTarget) return

    this.summaryTarget.replaceChildren()
    const rows = data.interval_changes || []
    if (!rows.length) {
      const wrap = document.createElement("div")
      wrap.className = "space-y-1"
      const p = document.createElement("p")
      p.className = "text-sm text-slate-600"
      p.textContent = "No data for this range."
      wrap.appendChild(p)
      if (data.empty_hint) {
        const hint = document.createElement("p")
        hint.className = "text-xs text-slate-500"
        hint.textContent = data.empty_hint
        wrap.appendChild(hint)
      }
      this.summaryTarget.appendChild(wrap)
      return
    }

    const outer = document.createElement("div")
    outer.className = "flex flex-col gap-1"

    if (data.alignment_note) {
      const note = document.createElement("p")
      note.className = "text-xs text-amber-800"
      note.textContent = data.alignment_note
      outer.appendChild(note)
    }

    const title = document.createElement("p")
    title.className = "text-xs font-medium uppercase text-slate-500"
    title.textContent = "Interval change (last vs first overlapping day)"

    const row = document.createElement("div")
    row.className = "flex flex-wrap gap-x-6 gap-y-1"

    for (const rowItem of rows) {
      const v = Number(rowItem.pct_change)
      const div = document.createElement("div")
      div.className =
        "text-sm font-semibold tabular-nums " +
        (v > 0 ? "text-emerald-600" : v < 0 ? "text-red-600" : "text-slate-600")
      const sign = v > 0 ? "+" : ""
      div.textContent = `${rowItem.label}: ${sign}${v.toFixed(2)}%`
      row.appendChild(div)
    }

    outer.appendChild(title)
    outer.appendChild(row)
    this.summaryTarget.appendChild(outer)
  }
};
