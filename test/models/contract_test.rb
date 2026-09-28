require "test_helper"

class ContractTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @insurance = contracts(:liability_insurance)
    @phone = contracts(:phone_plan)
  end

  test "valid fixtures" do
    assert @insurance.valid?
    assert @phone.valid?
  end

  test "needs a provider name or a merchant" do
    contract = @family.contracts.new(name: "Gym", owner: @admin)
    assert_not contract.valid?
    assert contract.errors.added?(:provider_name, :blank)

    contract.merchant = merchants(:netflix)
    assert contract.valid?
  end

  test "notice period needs both value and unit" do
    @insurance.notice_period_unit = nil
    assert_not @insurance.valid?
    assert @insurance.errors.added?(:notice_period_value, :incomplete)
  end

  test "end date cannot precede start date" do
    @insurance.ends_on = @insurance.started_on - 1.day
    assert_not @insurance.valid?
    assert @insurance.errors.added?(:ends_on, :before_start)
  end

  test "references must belong to the family" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)
    other_merchant = other_family.merchants.create!(name: "Elsewhere Inc")

    @insurance.account = other_account
    @insurance.merchant = other_merchant
    @insurance.owner = users(:empty)

    assert_not @insurance.valid?
    assert @insurance.errors.key?(:account)
    assert @insurance.errors.key?(:merchant)
    assert @insurance.errors.key?(:owner)
  end

  test "a contract cannot succeed itself" do
    @insurance.replaced_by = @insurance
    assert_not @insurance.valid?
    assert @insurance.errors.key?(:replaced_by)
  end

  test "portal url and document links must be http" do
    @insurance.portal_url = "javascript:alert(1)"
    @insurance.document_links = [ { "url" => "ftp://files.example.com/policy.pdf" } ]

    assert_not @insurance.valid?
    assert @insurance.errors.key?(:portal_url)
    assert @insurance.errors.key?(:document_links)
  end

  test "document links drop blank rows and keep labels" do
    @insurance.update!(document_links: [
      { "url" => " https://paperless.example.com/documents/42 ", "label" => "Policy" },
      { "url" => "" }
    ])

    assert_equal [ { "url" => "https://paperless.example.com/documents/42", "label" => "Policy" } ], @insurance.document_links
  end

  test "contract and customer numbers are encrypted when encryption is configured" do
    skip "Encryption not configured" unless Contract.encryption_ready?

    encrypted = Contract.encrypted_attributes.map(&:to_s)
    assert_includes encrypted, "contract_number"
    assert_includes encrypted, "customer_number"
  end

  test "numbers are masked to their last four characters" do
    assert_equal "•••• 7766", @phone.masked_contract_number
    assert_equal "•••• 3456", @phone.masked_customer_number
    assert_nil @insurance.masked_customer_number
  end

  test "owner defaults to the current user" do
    Current.stubs(:user).returns(@member)

    contract = @family.contracts.create!(name: "Gym", provider_name: "FitX", kind: "fitness")

    assert_equal @member, contract.owner
  end

  test "visibility is owner plus explicit shares, with no admin override" do
    private_to_member = @family.contracts.create!(name: "Member's own", provider_name: "Insurer", owner: @member)
    private_to_member.contract_shares.delete_all

    assert_includes Contract.accessible_by(@admin), @insurance
    assert_not_includes Contract.accessible_by(@admin), private_to_member
    assert_includes Contract.accessible_by(@member), private_to_member
    assert_includes Contract.accessible_by(@member), @phone
    assert_not_includes Contract.accessible_by(@member), @insurance
  end

  test "a related account grants no access" do
    @insurance.update!(account: accounts(:depository))

    assert Account.accessible_by(@member).include?(accounts(:depository))
    assert_not Contract.accessible_by(@member).include?(@insurance)
  end

  test "permission tiers" do
    assert_equal :owner, @phone.permission_for(@admin)
    assert_equal :read_only, @phone.permission_for(@member)
    assert @phone.viewable_by?(@member)
    assert_not @phone.editable_by?(@member)
    assert_not @phone.numbers_visible_to?(@member)
    assert_not @phone.manageable_by?(@member)

    contract_shares(:phone_plan_shared_with_member).update!(permission: "read_write")
    @phone.reload
    assert @phone.editable_by?(@member)
    assert @phone.numbers_visible_to?(@member)
    assert_not @phone.manageable_by?(@member)
    assert_includes Contract.editable_by(@member), @phone

    contract_shares(:phone_plan_shared_with_member).update!(permission: "full_control")
    assert @phone.reload.manageable_by?(@member)
  end

  test "new contracts are shared with the family when it shares by default" do
    @family.update!(default_account_sharing: "shared")

    contract = @family.contracts.create!(name: "Internet", provider_name: "Vodafone", kind: "internet", owner: @admin)

    assert_equal "read_write", contract.contract_shares.find_by(user: @member)&.permission
  end

  test "new contracts stay private when the family does not share by default" do
    @family.update!(default_account_sharing: "private")

    contract = @family.contracts.create!(name: "Internet", provider_name: "Vodafone", kind: "internet", owner: @admin)

    assert_empty contract.contract_shares
  end

  test "joining a sharing family shares existing contracts" do
    @family.update!(default_account_sharing: "shared")
    newcomer = @family.users.create!(email: "newcomer@example.com", password: "password123!", role: "member")

    @family.auto_share_existing_accounts_with(newcomer)

    assert @insurance.reload.viewable_by?(newcomer)
    assert_equal "read_write", @insurance.contract_shares.find_by(user: newcomer).permission
  end

  test "annual cost covers only active bills the viewer can see" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    recurring_transactions(:inactive_subscription).update!(contract: @phone)

    total, unconvertible = @phone.annual_cost_for(@admin)

    assert_equal 0, unconvertible
    assert_in_delta netflix.monthly_equivalent_amount.amount.abs * 12, total.amount, 0.01
    assert_equal "USD", total.currency.iso_code
  end

  test "annual cost is unknown without linked bills" do
    assert_equal [ nil, 0 ], @insurance.annual_cost_for(@admin)
  end

  test "linked bills keep their own visibility" do
    @family.update!(default_account_sharing: "private")
    private_account = @family.accounts.create!(name: "Admin only", balance: 0, currency: "USD",
                                               accountable: Depository.new, owner: @admin)
    private_account.account_shares.delete_all
    bill = @family.recurring_transactions.create!(
      account: private_account, name: "Phone bill", amount: 40, currency: "USD",
      expected_day_of_month: 3, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 3.days.from_now.to_date, status: "active", contract: @phone
    )

    assert_includes @phone.visible_recurring_transactions_for(@admin), bill
    assert_not_includes @phone.visible_recurring_transactions_for(@member), bill
    assert @phone.hidden_recurring_transactions_for?(@member)
    assert_equal [ nil, 0 ], @phone.annual_cost_for(@member)
  end

  test "a passed end date ends the contract for display" do
    @insurance.update!(ends_on: 2.days.ago.to_date)

    assert @insurance.active?
    assert @insurance.effectively_ended?
    assert_equal "ended", @insurance.display_status
  end

  test "cancellation lifecycle" do
    @insurance.record_cancellation!(sent_on: Date.current, ends_on: Date.current.end_of_year)
    assert @insurance.cancellation_sent?
    assert_equal Date.current, @insurance.cancelled_on

    @insurance.confirm_cancellation!(confirmed_on: Date.current)
    assert @insurance.cancelled?

    @insurance.withdraw_cancellation!
    assert @insurance.active?
    assert_nil @insurance.cancelled_on
    assert_nil @insurance.cancellation_confirmed_on
  end

  test "cancelling leaves linked bills running unless asked" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)
    ends_on = 2.months.from_now.to_date

    @phone.record_cancellation!(sent_on: Date.current, ends_on: ends_on)
    assert bill.reload.ends_never?

    @phone.record_cancellation!(sent_on: Date.current, ends_on: ends_on, end_linked_bills: true)
    assert bill.reload.ends_on_date?
    assert_equal ends_on, bill.end_on
  end

  test "running bills after end lists active bills once the contract ended" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    assert_empty @phone.running_bills_after_end

    @phone.update!(ends_on: 1.day.ago.to_date)
    assert_includes @phone.running_bills_after_end, bill
  end

  test "possible duplicates match provider and number" do
    twin = @family.contracts.create!(name: "Liability (old)", provider_name: "huk24",
                                     contract_number: "lv-2024-004711", owner: @admin)

    assert_includes @insurance.possible_duplicates, twin
    assert_not_includes @phone.possible_duplicates, twin
  end

  test "deleting a contract keeps its bills" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    @phone.destroy!

    assert_nil bill.reload.contract_id
  end

  test "deleting a merchant keeps the contract" do
    merchant = @family.merchants.create!(name: "Insurer Inc")
    @insurance.update!(merchant: merchant)

    merchant.destroy!

    assert_nil @insurance.reload.merchant_id
  end

  test "merging merchants moves contracts to the target" do
    source = @family.merchants.create!(name: "Telekom GmbH")
    target = @family.merchants.create!(name: "Telekom")
    @phone.update!(merchant: source)

    Merchant::Merger.new(family: @family, target_merchant: target, source_merchants: [ source ]).merge!

    assert_equal target, @phone.reload.merchant
  end

  test "a deleted owner's contracts pass to another member" do
    @family.update!(default_account_sharing: "shared")
    owned = @family.contracts.create!(name: "Bike insurance", provider_name: "Insurer", owner: @member)
    assert owned.contract_shares.exists?(user: @admin)

    @member.destroy!

    owned.reload
    assert_equal @admin, owned.owner
    assert_empty owned.contract_shares
  end

  test "a member moving family takes their contracts and leaves the household ties" do
    new_family = families(:empty)
    merchant = @family.merchants.create!(name: "Bike Insurer")
    @family.update!(default_account_sharing: "shared")
    owned = @family.contracts.create!(name: "Bike insurance", merchant: merchant, owner: @member,
                                      account: accounts(:depository))
    assert owned.contract_shares.exists?(user: @admin)
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: owned)
    @insurance.update!(replaced_by: owned)

    @member.transfer_to_family!(new_family)

    owned.reload
    assert_equal new_family, owned.family
    assert_nil owned.merchant_id
    assert_equal "Bike Insurer", owned.provider_name
    assert_nil owned.account_id
    assert_empty owned.contract_shares
    assert_nil bill.reload.contract_id
    assert_nil @insurance.reload.replaced_by_id
    assert_not ContractShare.exists?(user: @member)
  end

  test "bills can only link contracts of their family" do
    other = families(:empty).contracts.create!(name: "Elsewhere", provider_name: "X", owner: users(:empty))
    bill = recurring_transactions(:netflix_subscription)

    bill.contract = other
    assert_not bill.valid?
    assert bill.errors.added?(:contract, :wrong_family)
  end
end
