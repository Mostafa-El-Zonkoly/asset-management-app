import { Controller } from "@hotwired/stimulus"

// Risk vs return scatter: X = annualized volatility %, Y = annualized return %.
// One point per portfolio. Data comes from the server (only portfolios with
// enough history are included), so nothing is fabricated for short histories.
const COLORS = [
  "#2563eb", "#059669", "#d97706", "#dc2626", "#7c3aed",
  "#0891b2", "#db2777", "#65a30d", "#475569", "#ea580c",
]

export default class extends Controller {
  static targets = ["canvas"]
  static values = { points: Array }

  connect() {
    const pts = this.pointsValue || []
    if (!pts.length) return

    const datasets = pts.map((p, i) => ({
      label: p.label,
      data: [{ x: p.x, y: p.y }],
      backgroundColor: COLORS[i % COLORS.length],
      borderColor: COLORS[i % COLORS.length],
      pointRadius: 6,
      pointHoverRadius: 8,
    }))

    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "scatter",
      data: { datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "bottom" },
          tooltip: {
            callbacks: {
              label: (ctx) => `${ctx.dataset.label}: vol ${ctx.parsed.x}% · return ${ctx.parsed.y}%`,
            },
          },
        },
        scales: {
          x: { title: { display: true, text: "Annualized volatility %" }, beginAtZero: true },
          y: { title: { display: true, text: "Annualized return %" } },
        },
      },
    })
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }
}
