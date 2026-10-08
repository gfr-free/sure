import SortableController from "controllers/sortable_base";

// Reorders the report sections, which sit in a single column.
export default class extends SortableController {
  static ownKeysOnly = true;
  static holdHorizontalArrows = true;

  static saveUrl = "/reports/update_preferences";
  static orderPreference = "reports_section_order";
  static logLabel = "Reports Sortable";
}
