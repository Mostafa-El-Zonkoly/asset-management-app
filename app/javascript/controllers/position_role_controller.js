import { Controller } from "@hotwired/stimulus"

// Shows the Position Role selector for BUY, and Sell-From (+ specific lot picker
// and a Base-reduction warning) for SELL, based on the selected transaction type.
export default class extends Controller {
  static targets = ["type", "buyField", "sellField", "lotField", "lotSelect", "sellFrom", "quantity", "warning"]

  connect() {
    this.tempRemaining = null
    this.toggle()
  }

  selectedTypeText() {
    if (!this.hasTypeTarget) return ""
    const opt = this.typeTarget.options[this.typeTarget.selectedIndex]
    return (opt ? opt.text : "").trim().toLowerCase()
  }

  toggle() {
    const t = this.selectedTypeText()
    const isBuy = t === "buy"
    const isSell = t === "sell"
    if (this.hasBuyFieldTarget) this.buyFieldTarget.hidden = !isBuy
    if (this.hasSellFieldTarget) this.sellFieldTarget.hidden = !isSell
    this.onSellFromChange()
  }

  onSellFromChange() {
    const isSell = this.selectedTypeText() === "sell"
    const sf = this.hasSellFromTarget ? this.sellFromTarget.value : ""
    if (this.hasLotFieldTarget) this.lotFieldTarget.hidden = !(isSell && sf === "specific_lot")
    if (isSell && sf === "specific_lot") this.reloadLots()
    this.checkWarning()
  }

  reloadLots() {
    const assetId = this.fieldValue('[name="portfolio_transaction[asset_id]"]')
    const portfolioId = this.fieldValue('[name="portfolio_transaction[portfolio_id]"]')
    if (!assetId) return
    const url = `/transactions/lots?asset_id=${encodeURIComponent(assetId)}&portfolio_id=${encodeURIComponent(portfolioId || "")}`
    fetch(url, { headers: { Accept: "application/json" } })
      .then((r) => r.json())
      .then((data) => {
        const lots = data.lots || []
        this.tempRemaining = lots.filter((l) => l.role === "temporary").reduce((a, l) => a + (parseFloat(l.remaining) || 0), 0)
        if (this.hasLotSelectTarget) {
          const cur = this.lotSelectTarget.value
          this.lotSelectTarget.innerHTML =
            '<option value="">— select a lot —</option>' +
            lots.map((l) => `<option value="${l.buy_id}">${l.label}</option>`).join("")
          if (cur) this.lotSelectTarget.value = cur
        }
        this.checkWarning()
      })
      .catch(() => {})
  }

  checkWarning() {
    if (!this.hasWarningTarget) return
    const isSell = this.selectedTypeText() === "sell"
    const qty = this.hasQuantityTarget ? parseFloat(this.quantityTarget.value) || 0 : 0
    const sf = this.hasSellFromTarget ? this.sellFromTarget.value : "temporary_first"
    let baseReduction = 0
    if (isSell && qty > 0) {
      if (sf === "base") {
        baseReduction = qty
      } else if (sf === "temporary_first" && this.tempRemaining != null) {
        baseReduction = Math.max(0, qty - this.tempRemaining)
      }
    }
    if (baseReduction > 0) {
      this.warningTarget.textContent = `This sale will reduce the Strategic Base Position by ${(+baseReduction.toFixed(4))} shares.`
      this.warningTarget.hidden = false
    } else {
      this.warningTarget.hidden = true
    }
  }

  fieldValue(sel) {
    const el = this.element.querySelector(sel)
    return el ? el.value : ""
  }
}
