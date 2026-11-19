module CounterpartiesHelper
  CounterpartyPicker = Data.define(:current, :hidden, :people)

  # The drawer's person picker for `entry`: the person it is booked to and the
  # people the user may choose. A person the user can't see is never named
  # (hidden is true then). Nil when the entry can't be booked to anyone.
  def counterparty_picker_for(entry)
    assignment = Counterparty::Assignment.new(entry)
    booked_to = assignment.counterparty
    return nil unless booked_to || assignment.assignable?

    people = Current.family.counterparties.visible_to(Current.user).active.alphabetically.to_a
    current = booked_to && visible_counterparty(booked_to)
    CounterpartyPicker.new(current: current, hidden: booked_to.present? && current.nil?, people: (people + [ current ]).compact.uniq)
  end

  def visible_counterparty(counterparty)
    counterparty if Current.family.counterparties.visible_to(Current.user).exists?(counterparty.id)
  end
end
