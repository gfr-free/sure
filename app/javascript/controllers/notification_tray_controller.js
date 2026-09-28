import { Controller } from "@hotwired/stimulus";

// The tray is `position: fixed` with `left: 50%` (viewport-center) by
// default, which is correct for every single-column layout. Layouts with a
// sidebar (app, settings) opt in here so the tray centers on the actual
// content pane instead. A ResizeObserver on <main> catches every case that
// moves its bounds — window resize, sidebar drag-resize, sidebar
// collapse/expand — since all of those already reflow <main> natively; no
// cooperation needed from the sidebar controllers themselves.
export default class extends Controller {
  static targets = ["tray", "main"];

  connect() {
    this.resizeObserver = new ResizeObserver(() => this.reposition());
    this.resizeObserver.observe(this.mainTarget);
    this.reposition();

    this._onBeforeStreamRender = this.#deferWhileDialogOpen.bind(this);
    document.addEventListener(
      "turbo:before-stream-render",
      this._onBeforeStreamRender,
    );
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    document.removeEventListener(
      "turbo:before-stream-render",
      this._onBeforeStreamRender,
    );
  }

  reposition() {
    const rect = this.mainTarget.getBoundingClientRect();
    this.trayTarget.style.left = `${rect.left + rect.width / 2}px`;
  }

  // turbo_refreshes_with(method: :morph) is enabled app-wide
  // (_head.html.erb), and idiomorph resets any inline style a client
  // script set that isn't present in the freshly-fetched server HTML —
  // which `left` always is. `data-turbo-permanent` looked like the fix,
  // but it invokes idiomorph's node-identity matching (same id preserved
  // across ANY morphed page), which misbehaves once the id also exists
  // on structurally different layouts (app vs settings). Wiring this
  // narrower per-attribute event as a declarative action instead blocks
  // only `style` on this one element — no node-identity system involved.
  preserveStyle(event) {
    if (event.detail.attributeName === "style") event.preventDefault();
  }

  // A native <dialog> shown via showModal() (the transaction drawer, any
  // modal) renders in the browser's top layer, which sits above this tray
  // regardless of z-index. A "create a rule?" CTA streaming in while one is
  // open is invisible and unclickable until the dialog closes — and by then
  // its one-time flash has already been consumed server-side, so it never
  // gets a second chance to render. Defer the stream's own render call until
  // the open dialog's `close` event fires instead of applying it immediately.
  #deferWhileDialogOpen(event) {
    if (event.target.target !== "cta") return;

    const openDialog = document.querySelector("dialog[open]");
    if (!openDialog) return;

    const defaultRender = event.detail.render;
    event.detail.render = (streamElement) => {
      openDialog.addEventListener("close", () => defaultRender(streamElement), {
        once: true,
      });
    };
  }
}
