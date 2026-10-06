import { Controller } from "@hotwired/stimulus";

// Pending save per group, shared by the desktop and mobile sidebar lists.
const saveChains = new Map();

// Drag-and-drop ordering of the accounts inside one sidebar account group.
// Only rendered when the user picked "Manual" as their account order.
// Rows move by their grip handle: mouse drag, press-and-hold on touch, or
// Enter/Space plus the arrow keys. The new order is saved per user.
export default class extends Controller {
  static targets = ["item"];

  static values = {
    group: String,
    url: String,
    holdDelay: { type: Number, default: 400 },
  };

  connect() {
    this.draggedItem = null;
    this.pendingItem = null;
    this.keyboardItem = null;
    this.holdTimer = null;
    this.touchActive = false;
  }

  disconnect() {
    this.cancelHold();
  }

  // ===== Mouse =====
  // Rows only become draggable while their handle is pressed, so clicking the
  // account link and selecting text keep working as usual.
  enableDrag(event) {
    const item = event.currentTarget.closest(
      "[data-account-sortable-target='item']",
    );
    item.draggable = true;
    // A press released anywhere without dragging must not leave the row
    // draggable, or a later press on the row could start a reorder.
    window.addEventListener(
      "mouseup",
      () => {
        if (item !== this.draggedItem) item.draggable = false;
      },
      { once: true },
    );
  }

  dragStart(event) {
    if (!event.currentTarget.draggable) return;

    this.draggedItem = event.currentTarget;
    this.draggedItem.classList.add("opacity-50");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData(
      "text/plain",
      this.draggedItem.dataset.accountId,
    );
  }

  dragOver(event) {
    if (!this.draggedItem) return;

    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    this.showPlaceholder(event.clientY);
  }

  drop(event) {
    if (!this.draggedItem) return;

    event.preventDefault();
    this.moveTo(event.clientY);
    this.save();
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("opacity-50");
    event.currentTarget.draggable = false;
    this.draggedItem = null;
    this.clearPlaceholders();
  }

  // ===== Touch =====
  touchStart(event) {
    this.pendingItem = event.currentTarget.closest(
      "[data-account-sortable-target='item']",
    );
    this.touchStartY = event.touches[0].clientY;
    this.touchY = this.touchStartY;
    this.holdTimer = setTimeout(
      () => this.activateTouchDrag(),
      this.holdDelayValue,
    );
  }

  activateTouchDrag() {
    if (!this.pendingItem) return;

    this.touchActive = true;
    this.draggedItem = this.pendingItem;
    this.draggedItem.classList.add("opacity-50");
    if (navigator.vibrate) navigator.vibrate(30);
  }

  touchMove(event) {
    this.touchY = event.touches[0].clientY;

    if (!this.touchActive) {
      if (Math.abs(this.touchY - this.touchStartY) > 10) this.cancelHold();
      return;
    }

    event.preventDefault();
    this.showPlaceholder(this.touchY);
  }

  touchEnd() {
    this.cancelHold();

    if (this.touchActive && this.draggedItem) {
      this.moveTo(this.touchY);
      this.draggedItem.classList.remove("opacity-50");
      this.save();
    }

    this.clearPlaceholders();
    this.touchActive = false;
    this.draggedItem = null;
    this.pendingItem = null;
  }

  cancelHold() {
    if (this.holdTimer) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }
  }

  // ===== Keyboard =====
  handleKeyDown(event) {
    const item = event.currentTarget.closest(
      "[data-account-sortable-target='item']",
    );

    switch (event.key) {
      case "Enter":
      case " ":
        event.preventDefault();
        if (this.keyboardItem === item) {
          this.releaseKeyboardItem();
        } else {
          this.grabWithKeyboard(item);
        }
        break;
      case "ArrowUp":
        if (this.keyboardItem !== item) return;
        event.preventDefault();
        if (item.previousElementSibling) {
          this.element.insertBefore(item, item.previousElementSibling);
          event.currentTarget.focus();
        }
        break;
      case "ArrowDown":
        if (this.keyboardItem !== item) return;
        event.preventDefault();
        if (item.nextElementSibling) {
          this.element.insertBefore(item.nextElementSibling, item);
          event.currentTarget.focus();
        }
        break;
      case "Escape":
      case "Tab":
        if (this.keyboardItem) this.releaseKeyboardItem();
        break;
    }
  }

  // Leaving the sidebar's sort mode drops a row still held with the keyboard.
  releaseKeyboard() {
    if (this.keyboardItem) this.releaseKeyboardItem();
  }

  grabWithKeyboard(item) {
    if (this.keyboardItem) this.releaseKeyboardItem();

    this.keyboardItem = item;
    item.setAttribute("aria-grabbed", "true");
    item.classList.add("ring-2", "ring-alpha-black-100");
  }

  releaseKeyboardItem() {
    this.keyboardItem.setAttribute("aria-grabbed", "false");
    this.keyboardItem.classList.remove("ring-2", "ring-alpha-black-100");
    this.keyboardItem = null;
    this.save();
  }

  // ===== Shared =====
  // Item whose vertical centre lies below the pointer; the dragged row is
  // inserted before it, or appended when there is none.
  itemAfter(pointerY) {
    return this.itemTargets
      .filter((item) => item !== this.draggedItem)
      .find((item) => {
        const rect = item.getBoundingClientRect();
        return pointerY < rect.top + rect.height / 2;
      });
  }

  moveTo(pointerY) {
    const after = this.itemAfter(pointerY);
    if (after) {
      this.element.insertBefore(this.draggedItem, after);
    } else {
      this.element.appendChild(this.draggedItem);
    }
    this.clearPlaceholders();
  }

  showPlaceholder(pointerY) {
    this.clearPlaceholders();
    const after = this.itemAfter(pointerY);
    const others = this.itemTargets.filter((item) => item !== this.draggedItem);

    if (after) {
      after.classList.add("border-t-2", "border-primary");
    } else if (others.length > 0) {
      others[others.length - 1].classList.add("border-b-2", "border-primary");
    }
  }

  clearPlaceholders() {
    this.itemTargets.forEach((item) => {
      item.classList.remove("border-t-2", "border-b-2", "border-primary");
    });
  }

  currentOrder() {
    return this.itemTargets.map((item) => item.dataset.accountId);
  }

  // The sidebar renders each group in several tabs (All, Assets/Debts) and
  // again for mobile. Mirror the new order there so they agree before the
  // next page load.
  syncOtherLists(order) {
    const selector = `[data-controller~='account-sortable'][data-account-sortable-group-value='${this.groupValue}']`;

    document.querySelectorAll(selector).forEach((list) => {
      if (list === this.element) return;

      order.forEach((id) => {
        const item = list.querySelector(`[data-account-id='${id}']`);
        if (item) list.appendChild(item);
      });
    });
  }

  // Saves run one after another per group, so a slow earlier request can
  // never land after a newer one and overwrite the order on screen.
  save() {
    const order = this.currentOrder();
    this.syncOtherLists(order);

    const key = `${this.urlValue}:${this.groupValue}`;
    const previous = saveChains.get(key) ?? Promise.resolve();
    const request = previous.then(() => this.sendOrder(order));
    saveChains.set(key, request);
  }

  async sendOrder(order) {
    // The meta tag is absent only where forgery protection is off (tests).
    const csrfToken = document.querySelector('meta[name="csrf-token"]');

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken?.content ?? "",
        },
        body: JSON.stringify({ group: this.groupValue, account_ids: order }),
      });

      if (!response.ok) {
        console.error(
          "[Account Sortable] Failed to save account order:",
          response.status,
        );
      }
    } catch (error) {
      console.error(
        "[Account Sortable] Network error saving account order:",
        error,
      );
    }
  }
}
