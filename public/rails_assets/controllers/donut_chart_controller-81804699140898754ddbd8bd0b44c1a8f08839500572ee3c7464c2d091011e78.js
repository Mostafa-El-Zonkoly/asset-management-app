import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["canvas"]
  static values = { url: String }

  connect() {
    this.chart = null
    this.load(this.urlValue)
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }

  async load(url) {
    const res = await fetch(url, { headers: { Accept: "application/json" } })
    const data = await res.json()
    if (!data.length) {
      if (this.chart) this.chart.destroy()
      return
    }
    const labels = data.map((d) => d.category || d.sector || d.label || "—")
    const values = data.map((d) => d.value)

    if (this.chart) this.chart.destroy()

    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "doughnut",
      data: {
        labels,
        datasets: [
          {
            data: values,
            backgroundColor: [
              "rgb(59, 130, 246)",
              "rgb(16, 185, 129)",
              "rgb(245, 158, 11)",
              "rgb(239, 68, 68)",
              "rgb(139, 92, 246)",
              "rgb(236, 72, 153)",
            ],
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { position: "bottom" } },
      },
    })
  }
};
