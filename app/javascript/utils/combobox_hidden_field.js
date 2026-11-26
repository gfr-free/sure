// The hidden input hotwire_combobox submits for the combobox whose visible input is given.
export default function comboboxHiddenField(input) {
  return input?.closest(".hw-combobox")?.querySelector("[data-hw-combobox-target='hiddenField']") || null
}
