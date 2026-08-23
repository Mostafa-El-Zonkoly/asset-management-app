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

  setRange(event) {
    const range = event.currentTarget.dataset.range
    const u = new URL(this.urlValue, window.location.origin)
    u.searchParams.set("range", range)
    this.load(u.toString())
  }

  async load(url) {
    const res = await fetch(url, { headers: { Accept: "application/json" } })
    const data = await res.json()
    if (!data.length) {
      if (this.chart) this.chart.destroy()
      return
    }
    const labels = data.map((d) => d.date)
    const values = data.map((d) => d.value ?? d.price)

    if (this.chart) this.chart.destroy()

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
};
