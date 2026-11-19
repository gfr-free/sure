require "test_helper"

# Split rows that name a person (see Counterparty::Assignment).
class SplitsControllerCounterpartyTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @family = families(:dylan_family)
    @person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    @entry = create_transaction(amount: 100, name: "Dinner", account: accounts(:depository))
  end

  test "the split dialog offers people to preview users" do
    get new_transaction_split_path(@entry)

    assert_select "input[name=?]", "split[splits][0][counterparty_id]"
  end

  test "a row with a person books that part to them" do
    post transaction_split_path(@entry), params: split_params([ [ "Mine", "-60", "" ], [ "Alex", "-40", @person.id ] ])

    children = @entry.reload.child_entries.in_split_order.to_a
    assert_equal 2, children.size
    assert_nil Counterparty::Assignment.new(children.first).counterparty
    assert_equal @person, Counterparty::Assignment.new(children.last).counterparty
    assert_equal(-40, @person.accounts.sole.entries.where(entryable_type: "Transaction").sole.amount)
  end

  test "editing the split replaces the person legs" do
    post transaction_split_path(@entry), params: split_params([ [ "Mine", "-60", "" ], [ "Alex", "-40", @person.id ] ])
    old_leg = @person.accounts.sole.entries.where(entryable_type: "Transaction").sole

    patch transaction_split_path(@entry), params: split_params([ [ "Mine", "-50", "" ], [ "Alex", "-50", @person.id ] ])

    assert_not Entry.exists?(old_leg.id)
    assert_equal(-50, @person.accounts.sole.entries.where(entryable_type: "Transaction").sole.amount)
  end

  test "unsplitting removes the person legs" do
    post transaction_split_path(@entry), params: split_params([ [ "Mine", "-60", "" ], [ "Alex", "-40", @person.id ] ])

    delete transaction_split_path(@entry)

    assert_not @entry.reload.split_parent?
    assert_empty @person.accounts.sole.entries.where(entryable_type: "Transaction")
  end

  test "a person the user may not book onto stops the split" do
    stranger = families(:empty).counterparties.create!(name: "Stranger", default_currency: "USD")

    post transaction_split_path(@entry), params: split_params([ [ "Mine", "-60", "" ], [ "Them", "-40", stranger.id ] ])

    assert_not @entry.reload.split_parent?
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  private
    def split_params(rows)
      { split: { splits: rows.map { |name, amount, person_id| { name: name, amount: amount, category_id: "", counterparty_id: person_id } } } }
    end
end
