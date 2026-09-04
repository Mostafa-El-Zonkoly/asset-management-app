import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["wrapper", "button", "panel", "nav", "burger"]

  connect() {
    this.boundCloseOnOutside = this.closeOnOutsideClick.bind(this)
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    this.closeAll()
  }

  disconnect() {
    this.removeListeners()
  }

  toggle(event) {
    event.stopPropagation()
    const wrapper = event.currentTarget.closest("[data-nav-menus-target='wrapper']")
    const panel = wrapper.querySelector("[data-nav-menus-target='panel']")
    const button = wrapper.querySelector("[data-nav-menus-target='button']")
    const isOpen = panel.classList.contains("nav-menu-panel--open")

    this.closeAll()

    if (!isOpen) {
      this.open(panel, button)
    }
  }

  toggleMobile(event) {
    event.stopPropagation()
    if (!this.hasNavTarget) return
    const open = this.navTarget.classList.toggle("app-header__nav--open")
    if (this.hasBurgerTarget) {
      this.burgerTarget.setAttribute("aria-expanded", open ? "true" : "false")
    }
    if (!open) this.closeAll()
  }

  open(panel, button) {
    panel.classList.add("nav-menu-panel--open")
    panel.removeAttribute("hidden")
    panel.style.display = "block"
    button.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.boundCloseOnOutside)
    document.addEventListener("keydown", this.boundCloseOnEscape)
  }

  closeOnOutsideClick(event) {
    if (this.element.contains(event.target)) return
    this.closeAll()
  }

  closeOnEscape(event) {
    if (event.key === "Escape") this.closeAll()
  }

  closeAll() {
    this.removeListeners()
    this.wrapperTargets.forEach((wrapper) => {
      const panel = wrapper.querySelector("[data-nav-menus-target='panel']")
      const button = wrapper.querySelector("[data-nav-menus-target='button']")
      if (!panel || !button) return

      panel.classList.remove("nav-menu-panel--open")
      panel.setAttribute("hidden", "")
      panel.style.display = "none"
      button.setAttribute("aria-expanded", "false")
    })
  }

  removeListeners() {
    document.removeEventListener("click", this.boundCloseOnOutside)
    document.removeEventListener("keydown", this.boundCloseOnEscape)
  }
}
