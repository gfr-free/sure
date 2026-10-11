import SortableController from "controllers/sortable_base";

// Reorders the dashboard cards, which sit in a one- or two-column grid.
export default class extends SortableController {
  // Hold delay to require deliberate press-and-hold before activating drag mode
  static values = {
    holdDelay: { type: Number, default: 800 },
  };

  static dropTarget = "nearest";
  static guardTouchHold = true;
  static ownKeysOnly = true;

  static saveUrl = "/dashboard/preferences";
  static orderPreference = "section_order";
  static logLabel = "Dashboard Sortable";
}
