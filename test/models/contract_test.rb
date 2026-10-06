require "test_helper"

class ContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "the provider is the merchant, and a contract can do without one" do
    contract = @family.contracts.new(name: "Gym", owner: @admin)
    assert contract.valid?
    assert_nil contract.provider_display_name

    contract.merchant = merchants(:netflix)
    assert_equal "Netflix", contract.provider_display_name
  end

  test "an end needs a date" do
    @insurance.status = "ended"
    assert_not @insurance.valid?
    assert @insurance.errors.added?(:ends_on, :blank)
  end

  test "merchant_named matches the family's merchants regardless of case" do
    assert_equal merchants(:netflix), Contract.merchant_named(@family, @admin, " netflix ")
    assert_nil Contract.merchant_named(@family, @admin, "Nobody GmbH")
    assert_nil Contract.merchant_named(@family, @admin, "")
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
    assert_equal "••••", Contract.mask("123"), "short values mask entirely or the mask reveals them whole"
  end

  test "owner defaults to the current user" do
    Current.stubs(:user).returns(@member)

    contract = @family.contracts.create!(name: "Gym", kind: "fitness")

    assert_equal @member, contract.owner
  end

  test "visibility is owner plus explicit shares, with no admin override" do
    private_to_member = @family.contracts.create!(name: "Member's own", owner: @member)
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

    contract = @family.contracts.create!(name: "Internet", kind: "internet", owner: @admin)

    assert_equal "read_write", contract.contract_shares.find_by(user: @member)&.permission
  end

  test "new contracts stay private when the family does not share by default" do
    @family.update!(default_account_sharing: "private")

    contract = @family.contracts.create!(name: "Internet", kind: "internet", owner: @admin)

    assert_empty contract.contract_shares
  end

  test "joining a sharing family shares existing contracts" do
    @family.update!(default_account_sharing: "shared")
    newcomer = @family.users.create!(email: "newcomer@example.com", password: "password123!", role: "member")

    @family.auto_share_existing_accounts_with(newcomer)

    assert @insurance.reload.viewable_by?(newcomer)
    assert_equal "read_write", @insurance.contract_shares.find_by(user: newcomer).permission
  end

  test "document links keep a known role and drop an unknown one" do
    @insurance.update!(document_links: [
      { "url" => "https://paperless.example.com/documents/42", "role" => "terms" },
      { "url" => "https://paperless.example.com/documents/43", "role" => "bogus" }
    ])

    assert_equal [
      { "url" => "https://paperless.example.com/documents/42", "role" => "terms" },
      { "url" => "https://paperless.example.com/documents/43" }
    ], @insurance.document_links
  end

  test "a contract that needs no notice keeps no notice terms and has no deadline" do
    @insurance.update!(notice_not_required: true)

    assert_nil @insurance.notice_period_value
    assert_nil @insurance.notice_period_unit
    assert_nil @insurance.notice_anchor
    assert_nil @insurance.notice_deadline
    assert_nil @insurance.notice_schedule.earliest_end_on
    assert_equal 12, @insurance.renewal_period_months, "the term itself stays"
  end

  test "price guarantee is read for energy contracts only" do
    contract = @family.contracts.create!(name: "Power", kind: "energy", owner: @admin,
                                         details: { "price_guarantee_until" => "2027-03-31" })
    assert_equal Date.new(2027, 3, 31), contract.price_guarantee_until

    assert_nil @phone.price_guarantee_until
  end

  test "savings count the yearly cost of contracts ended in the last twelve months" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    @phone.end_contract!(on: 1.month.ago.to_date)
    @insurance.end_contract!(on: 13.months.ago.to_date)

    total, count = Contract.annual_savings_for([ @phone, @insurance ], @admin)

    assert_equal 1, count
    assert_in_delta netflix.monthly_equivalent_amount.amount.abs * 12, total.amount, 0.01
  end

  test "savings subtract what the successor costs" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    successor = @family.contracts.create!(name: "New phone", kind: "mobile", owner: @admin)
    cheaper = @family.recurring_transactions.create!(
      name: "New phone bill", amount: 5, currency: "USD", expected_day_of_month: 3,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: 3.days.from_now.to_date,
      status: "active", contract: successor
    )
    @phone.update!(replaced_by: successor)
    @phone.end_contract!(on: 1.month.ago.to_date)

    total, = Contract.annual_savings_for([ @phone, successor ], @admin)

    expected = (netflix.monthly_equivalent_amount.amount.abs - cheaper.monthly_equivalent_amount.amount.abs) * 12
    assert_in_delta expected, total.amount, 0.01
  end

  test "savings count a shared successor once and a chain from its first contract" do
    bundle = @family.contracts.create!(name: "Bundle", kind: "internet", owner: @admin)
    bill_for(bundle, 50)
    bill_for(@phone, 40)
    bill_for(@insurance, 20)
    [ @phone, @insurance ].each do |contract|
      contract.update!(replaced_by: bundle)
      contract.end_contract!(on: 1.month.ago.to_date)
    end

    total, count = Contract.annual_savings_for([ @phone, @insurance, bundle ], @admin)
    assert_equal 2, count
    assert_in_delta (40 + 20 - 50) * 12, total.amount, 0.01

    # Phone -> interim -> bundle, phone and interim both ended: phone against bundle.
    @insurance.update_columns(replaced_by_id: nil, ends_on: 2.years.ago.to_date)
    interim = @family.contracts.create!(name: "Interim", kind: "mobile", owner: @admin)
    bill_for(interim, 45)
    @phone.update_columns(replaced_by_id: interim.id)
    interim.update!(replaced_by: bundle)
    interim.end_contract!(on: 1.week.ago.to_date)

    total, count = Contract.annual_savings_for([ @phone, @insurance, interim, bundle ], @admin)
    assert_equal 2, count
    assert_in_delta (40 - 50) * 12, total.amount, 0.01
  end

  test "a bill still running after the contract ended is not saved" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    @phone.end_contract!(on: 1.month.ago.to_date, bills: RecurringTransaction.none)

    total, count = Contract.annual_savings_for([ @phone ], @admin)
    assert_equal 1, count
    assert_equal 0, total.amount
  end

  test "savings are unknown without a recently ended contract" do
    assert_equal [ nil, 0 ], Contract.annual_savings_for([ @phone, @insurance ], @admin)
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

  test "annual cost keeps bills without an exchange rate in their own currency" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone, currency: "EUR")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    total, unconvertible, unconverted = @phone.annual_cost_for(@admin)

    assert_equal Money.new(0, "USD"), total
    assert_equal 1, unconvertible
    assert_equal [ "EUR" ], unconverted.keys
    assert_in_delta netflix.monthly_equivalent_amount.amount.abs * 12, unconverted["EUR"].amount, 0.01
  end

  test "summed costs keep bills without an exchange rate apart by currency" do
    costs = [
      [ Money.new(100, "USD"), 0, {} ],
      [ Money.new(0, "USD"), 1, { "EUR" => Money.new(50, "EUR") } ],
      [ Money.new(20, "USD"), 1, { "EUR" => Money.new(30, "EUR") } ],
      [ nil, 0, {} ],
      nil
    ]

    total, unconvertible, unconverted = Contract.sum_costs(costs)

    assert_equal Money.new(120, "USD"), total
    assert_equal 2, unconvertible
    assert_equal({ "EUR" => Money.new(80, "EUR") }, unconverted)
    assert_equal [ nil, 0, {} ], Contract.sum_costs([ [ nil, 0, {} ] ])
  end

  test "annual cost is unknown without linked bills" do
    assert_equal [ nil, 0, {} ], @insurance.annual_cost_for(@admin)
  end

  test "a price increase of a visible active bill shows on its contract" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    older = netflix.recurring_price_changes.create!(effective_on: 3.months.ago.to_date, previous_amount: 12.99,
                                                    new_amount: 13.99, currency: "USD", source: "detected")
    latest = netflix.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 13.99,
                                                     new_amount: 15.99, currency: "USD", source: "detected")

    increases = Contract.recent_price_increases_for([ @phone, @insurance ], @admin)

    assert_equal({ @phone.id => latest }, increases)
    assert_equal [ latest, older ], @phone.price_changes_for(@admin).to_a
  end

  test "no price badge when the latest change was a cut, is too old or the bill is not active" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    netflix.recurring_price_changes.create!(effective_on: 2.months.ago.to_date, previous_amount: 12.99,
                                            new_amount: 15.99, currency: "USD", source: "detected")
    netflix.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 15.99,
                                            new_amount: 14.99, currency: "USD", source: "detected")
    inactive = recurring_transactions(:inactive_subscription)
    inactive.update!(contract: @insurance)
    inactive.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 8.99,
                                             new_amount: 9.99, currency: "USD", source: "detected")
    stale = @family.recurring_transactions.create!(
      account: accounts(:depository), name: "Old insurance", amount: 20, currency: "USD",
      expected_day_of_month: 3, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 3.days.from_now.to_date, status: "active", contract: @insurance
    )
    stale.recurring_price_changes.create!(effective_on: 13.months.ago.to_date, previous_amount: 18,
                                          new_amount: 20, currency: "USD", source: "detected")

    assert_empty Contract.recent_price_increases_for([ @phone, @insurance ], @admin)
    assert_empty Contract.recent_price_increases_for([], @admin)
  end

  test "a price cut on one bill does not hide a rise on another" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    rise = netflix.recurring_price_changes.create!(effective_on: 2.months.ago.to_date, previous_amount: 12.99,
                                                   new_amount: 15.99, currency: "USD", source: "detected")
    other = @family.recurring_transactions.create!(
      account: accounts(:depository), name: "Data add-on", amount: 8, currency: "USD",
      expected_day_of_month: 3, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 3.days.from_now.to_date, status: "active", contract: @phone
    )
    other.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 10,
                                          new_amount: 8, currency: "USD", source: "detected")

    assert_equal({ @phone.id => rise }, Contract.recent_price_increases_for([ @phone ], @admin))
  end

  test "price changes keep their bill's visibility" do
    @family.update!(default_account_sharing: "private")
    private_account = @family.accounts.create!(name: "Admin only", balance: 0, currency: "USD",
                                               accountable: Depository.new, owner: @admin)
    private_account.account_shares.delete_all
    bill = @family.recurring_transactions.create!(
      account: private_account, name: "Phone bill", amount: 40, currency: "USD",
      expected_day_of_month: 3, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 3.days.from_now.to_date, status: "active", contract: @phone
    )
    change = bill.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 35,
                                                  new_amount: 40, currency: "USD", source: "detected")

    assert_equal({ @phone.id => change }, Contract.recent_price_increases_for([ @phone ], @admin))
    assert_empty Contract.recent_price_increases_for([ @phone ], @member)
    assert_empty @phone.price_changes_for(@member)
  end

  test "the next payment is the earliest due date across the visible active bills" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    later = @family.recurring_transactions.create!(
      account: accounts(:depository), name: "Data add-on", amount: 8, currency: "USD",
      expected_day_of_month: 3, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 20.days.from_now.to_date, status: "active", contract: @phone
    )
    inactive = recurring_transactions(:inactive_subscription)
    inactive.update!(contract: @phone)

    # Creating a bill materializes occurrences, so read the dates back rather
    # than assuming them.
    first_due = [ netflix, later ].map { |bill| bill.reload.next_due_date }.min
    expected = [ netflix, later ].select { |bill| bill.next_due_date == first_due }
    assert_equal expected.map(&:id).sort, @phone.next_payments_for(@admin).map(&:id).sort

    # Bills due the same day are one next payment; inactive ones never count.
    RecurringTransaction.any_instance.stubs(:next_due_date).returns(first_due)
    assert_equal [ netflix, later ].map(&:id).sort, @phone.next_payments_for(@admin).map(&:id).sort
    assert_empty @insurance.next_payments_for(@admin)
  end

  test "payments are the confirmed allocations of the linked bills, newest first" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    occurrence = netflix.recurring_occurrences.create!(family: @family, original_due_on: 2.months.ago.to_date,
                                                       due_on: 2.months.ago.to_date, currency: "USD")
    entry = accounts(:depository).entries.create!(date: 2.months.ago.to_date, amount: 15.99, currency: "USD",
                                                  name: "NETFLIX.COM", entryable: Transaction.new)
    recent = occurrence.allocations.create!(entry: entry, allocated_amount: 15.99, currency: "USD",
                                            state: "confirmed", source: "user_confirmed")
    old = occurrence.allocations.create!(allocated_amount: 1, currency: "USD", paid_on: 14.months.ago.to_date,
                                         state: "confirmed", source: "user_created")
    occurrence.allocations.create!(allocated_amount: 2, currency: "USD", state: "suggested", source: "auto_matched")

    assert_equal [ recent, old ], @phone.payments_for(@admin).to_a
    assert_equal [ recent ], @phone.payments_for(@admin, since: 12.months.ago.to_date).to_a
    assert_empty @insurance.payments_for(@admin)
  end

  test "payments keep the visibility of their bill and their account" do
    @family.update!(default_account_sharing: "private")
    private_account = @family.accounts.create!(name: "Admin only", balance: 0, currency: "USD",
                                               accountable: Depository.new, owner: @admin)
    private_account.account_shares.delete_all
    legacy_bill = @family.recurring_transactions.create!(
      name: "Phone bill", amount: 40, currency: "USD", expected_day_of_month: 3,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: 3.days.from_now.to_date,
      status: "active", contract: @phone
    )
    occurrence = legacy_bill.recurring_occurrences.create!(family: @family, original_due_on: 1.month.ago.to_date,
                                                           due_on: 1.month.ago.to_date, currency: "USD")
    hidden_entry = private_account.entries.create!(date: 1.month.ago.to_date, amount: 40, currency: "USD",
                                                   name: "PHONE CO", entryable: Transaction.new)
    hidden = occurrence.allocations.create!(entry: hidden_entry, allocated_amount: 40, currency: "USD",
                                            state: "confirmed", source: "user_confirmed")
    manual = occurrence.allocations.create!(allocated_amount: 5, currency: "USD", paid_on: 2.days.ago.to_date,
                                            state: "confirmed", source: "user_created")

    assert_equal [ manual, hidden ], @phone.payments_for(@admin).to_a
    assert_equal [ manual ], @phone.payments_for(@member).to_a
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
    assert_equal [ nil, 0, {} ], @phone.annual_cost_for(@member)
  end

  test "a passed end date ends the contract for display" do
    @insurance.update!(ends_on: 2.days.ago.to_date)

    assert @insurance.active?
    assert @insurance.effectively_ended?
    assert_equal "ended", @insurance.display_status
  end

  test "ending shows the contract as ending until the date, then ended" do
    ends_on = Date.current.end_of_year
    @insurance.end_contract!(on: ends_on)

    assert @insurance.ended?
    assert @insurance.open?
    assert_equal "ending", @insurance.display_status
    assert_nil @insurance.notice_deadline, "an ended contract has nothing left to cancel"

    travel_to ends_on + 1.day do
      assert_equal "ended", @insurance.display_status
      assert_not @insurance.open?
    end
  end

  test "ending a contract ends its linked bills on the same date, and reopening restores them" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)
    ends_on = 2.months.from_now.to_date

    @phone.end_contract!(on: ends_on)
    assert bill.reload.ends_on_date?
    assert_equal ends_on, bill.end_on
    assert_equal @phone.id, bill.contract_id, "past payments stay with the contract"

    @phone.reopen!
    assert @phone.active?
    assert_nil @phone.ends_on
    assert bill.reload.ends_never?
  end

  test "ending only touches the bills passed in" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    @phone.end_contract!(on: 1.month.from_now.to_date, bills: RecurringTransaction.none)

    assert bill.reload.ends_never?
  end

  test "running bills after end lists active bills once the contract ended" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    assert_empty @phone.running_bills_after_end

    @phone.update!(ends_on: 1.day.ago.to_date)
    assert_includes @phone.running_bills_after_end, bill
  end

  test "possible duplicates match merchant and number" do
    @insurance.update!(merchant: merchants(:one))
    twin = @family.contracts.create!(name: "Liability (old)", merchant: merchants(:one),
                                     contract_number: "lv-2024-004711", owner: @admin)
    other_merchant = @family.contracts.create!(name: "Liability (other)", merchant: merchants(:amazon),
                                               contract_number: "lv-2024-004711", owner: @admin)

    assert_includes @insurance.possible_duplicates, twin
    assert_not_includes @insurance.possible_duplicates, other_merchant
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
    assert @insurance.valid?
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
    owned = @family.contracts.create!(name: "Bike insurance", owner: @member)
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
    document = owned.contract_documents.new
    document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "policy.pdf", content_type: "application/pdf")
    document.save!
    family_document = @family.family_documents.create!(filename: "policy.pdf", status: "ready", provider_file_id: "file-move-1")
    document.update!(ai_searchable: true, family_document: family_document)
    uploading = owned.contract_documents.new(ai_searchable: true) # upload still running
    uploading.file.attach(io: StringIO.new("%PDF-1.4"), filename: "terms.pdf", content_type: "application/pdf")
    uploading.save!

    @member.transfer_to_family!(new_family)

    owned.reload
    assert_equal new_family, owned.family
    assert_equal new_family.merchants.find_by!(name: "Bike Insurer"), owned.merchant
    assert_nil owned.account_id
    assert_empty owned.contract_shares
    assert_nil bill.reload.contract_id
    assert_nil @insurance.reload.replaced_by_id
    assert_not ContractShare.exists?(user: @member)
    # The indexed copy lives in the old family's document store; the move
    # removes it and resets the opt-in so the owner re-opts in the new family.
    document.reload
    assert_nil document.family_document_id
    assert_not document.ai_searchable?
    assert_enqueued_with(job: ContractDocumentUnindexJob, args: [ family_document ])
    assert_not uploading.reload.ai_searchable?, "an upload still running is opted out too"
  end

  test "bills can only link contracts of their family" do
    other = families(:empty).contracts.create!(name: "Elsewhere", owner: users(:empty))
    bill = recurring_transactions(:netflix_subscription)

    bill.contract = other
    assert_not bill.valid?
    assert bill.errors.added?(:contract, :wrong_family)
  end

  private
    def bill_for(contract, amount)
      @family.recurring_transactions.create!(
        name: "#{contract.name} bill", amount: amount, currency: "USD", expected_day_of_month: 3,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: 3.days.from_now.to_date,
        status: "active", contract: contract
      )
    end
end
