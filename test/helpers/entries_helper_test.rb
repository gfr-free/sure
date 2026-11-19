require "test_helper"

class EntriesHelperTest < ActionView::TestCase
  include EntriesTestHelper

  setup do
    @account = families(:dylan_family).accounts.first
    @parent = create_transaction(account: @account, amount: 90, name: "Groceries")
    @parent.split!([
      { name: "First", amount: 30 },
      { name: "Second", amount: 30 },
      { name: "Third", amount: 30 }
    ])
  end

  test "lists split children in the order they were entered, as the split views do" do
    entries = Entry.where(parent_entry_id: @parent.id).reverse_chronological.to_a

    group = group_split_entries(entries, { @parent.id => @parent }).sole

    assert_equal %w[First Second Third], group.children.map(&:name)
    assert_equal @parent.child_entries.in_split_order.map(&:name), group.children.map(&:name)
  end

  test "breaks a created_at tie between split children by id" do
    @parent.child_entries.update_all(created_at: 1.day.ago.change(usec: 0))
    entries = Entry.where(parent_entry_id: @parent.id).reverse_chronological.to_a

    group = group_split_entries(entries, { @parent.id => @parent }).sole

    assert_equal @parent.child_entries.in_split_order.map(&:id), group.children.map(&:id)
  end
end
