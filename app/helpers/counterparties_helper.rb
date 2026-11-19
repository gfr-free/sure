module CounterpartiesHelper
  CounterpartyPicker = Data.define(:current, :people)

  # The drawer's person picker for `entry`: the person it is booked to and the
  # people the user may choose. Nil when the entry can't be booked to anyone.
  def counterparty_picker_for(entry)
    assignment = Counterparty::Assignment.new(entry)
    current = assignment.counterparty
    return nil unless current || assignment.assignable?

    people = Current.family.counterparties.visible_to(Current.user).active.alphabetically.to_a
    CounterpartyPicker.new(current: current, people: (people + [ current ]).compact.uniq)
  end
end
