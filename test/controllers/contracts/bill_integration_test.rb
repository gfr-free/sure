require "test_helper"

# Where contracts surface outside their own pages: the bill page and pane, the
# transaction page, and ending bills that outlive their contract.
class Contracts::BillIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @admin = users(:family_admin)
    @member = users(:family_member)
    [ @admin, @member ].each { |user| user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true)) }
    @family = @admin.family
    @bill = recurring_transactions(:netflix_subscription)
    @contract = contracts(:phone_plan)
    ensure_tailwind_build
  end

  test "bill page links its contract" do
    @bill.update!(contract: @contract)

    get bill_url(@bill)

    assert_response :success
    assert_select "a[href=?]", contract_path(@contract), text: /#{@contract.name}/
  end

  test "bill page offers to record a contract when none is linked" do
    get bill_url(@bill)

    assert_select "a[href=?]", new_contract_path(recurring_transaction_id: @bill.id)
  end

  test "bill page hides a contract the viewer cannot see" do
    @contract.contract_shares.delete_all
    @bill.update!(contract: @contract)
    sign_in @member

    get bill_url(@bill)

    assert_response :success
    assert_select "a[href=?]", contract_path(@contract), count: 0
  end

  test "flags a bill still running after its contract ended and ends it" do
    @bill.update!(contract: @contract)
    @contract.update!(ends_on: 3.days.ago.to_date)

    get bill_url(@bill)
    assert_includes response.body, I18n.t("bills.contract_line.ended_on", date: I18n.l(@contract.ends_on, format: :long))

    post end_linked_bills_contract_url(@contract)

    @bill.reload
    assert @bill.ends_on_date?
    assert_equal @contract.ends_on, @bill.end_on

    get bill_url(@bill)
    assert_not_includes response.body, I18n.t("bills.contract_line.ended_on", date: I18n.l(@contract.ends_on, format: :long))
  end

  test "ending linked bills needs edit rights" do
    @bill.update!(contract: @contract)
    @contract.update!(ends_on: 3.days.ago.to_date)
    sign_in @member

    post end_linked_bills_contract_url(@contract)

    assert_response :not_found
    assert @bill.reload.ends_never?
  end

  test "transaction page links the contract of the bill it paid" do
    @bill.update!(contract: @contract)
    entry = accounts(:depository).entries.create!(date: Date.current, amount: 15.99, currency: "USD", name: "Netflix", entryable: Transaction.new)
    @bill.recurring_occurrences.destroy_all
    occurrence = @bill.recurring_occurrences.create!(family: @family, original_due_on: Date.current, due_on: Date.current,
                                                     currency: "USD", expected_amount: 15.99, status: "scheduled")
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)

    get transaction_url(entry), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_select "a[href=?]", contract_path(@contract)
  end
end
