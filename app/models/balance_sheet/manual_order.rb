# Sorting by a list the user saved with the manual account order (see
# User#manual_list_order): entries in the list first, in its order, the rest
# after them in the order they came in.
module BalanceSheet::ManualOrder
  def self.sort(items, positions)
    return items if positions.empty?

    items.each_with_index.sort_by do |item, index|
      position = positions[yield(item).to_s]
      position ? [ 0, position, index ] : [ 1, 0, index ]
    end.map(&:first)
  end
end
