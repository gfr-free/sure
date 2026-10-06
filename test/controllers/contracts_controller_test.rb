require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @admin = users(:family_admin)
    @member = users(:family_member)
    enable_preview(@admin)
    enable_preview(@member)
    @family = @admin.family
    @insurance = contracts(:liability_insurance)
    @phone = contracts(:phone_plan)
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))

    get contracts_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "follows the family's bills toggle" do
    @family.update!(recurring_transactions_disabled: true)

    get contracts_url

    assert_redirected_to root_path
  end

  test "index lists the user's contracts inside the bills view switcher" do
    get contracts_url

    assert_response :success
    assert_select "main h1", text: I18n.t("contracts.index.title")
    assert_select "a[aria-current=true]", text: I18n.t("bills.views.contracts")
    assert_select "a[href=?]", contract_path(@insurance)
    assert_select "a[href=?]", contract_path(@phone)
  end

  test "index shows the monthly average and a badge for a price increase" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    change = netflix.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 12.99,
                                                     new_amount: 15.99, currency: "USD", source: "detected")

    get contracts_url

    assert_response :success
    assert_select "p", text: I18n.t("contracts.index.monthly_cost_label")
    assert_select "span[title=?]", I18n.t("contracts.price_increased_on", date: I18n.l(change.effective_on, format: :short))
  end

  test "index shows what contracts ended in the last year save" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    @phone.end_contract!(on: 1.month.ago.to_date)

    get contracts_url

    assert_response :success
    assert_select "p", text: /#{Regexp.escape(I18n.t("contracts.index.savings", count: 1))}/
  end

  test "a contract that needs no notice saves without notice terms" do
    patch contract_url(@insurance), params: { contract: { notice_not_required: "1", notice_period_value: 3, notice_period_unit: "months" } }

    assert_redirected_to contract_url(@insurance)
    @insurance.reload
    assert @insurance.notice_not_required?
    assert_nil @insurance.notice_period_value

    get contract_url(@insurance)
    assert_select "dd", text: I18n.t("contracts.terms.not_required")
  end

  test "a new contract cannot replace one the user may not change" do
    hidden = @family.contracts.create!(name: "Member's", kind: "mobile", owner: @member)
    hidden.contract_shares.delete_all

    assert_no_difference -> { @family.contracts.count } do
      post contracts_url, params: { contract: { name: "Mine", kind: "mobile", predecessor_id: hidden.id } }
    end
    assert_response :unprocessable_entity
    assert_nil hidden.reload.replaced_by
  end

  test "a contract that is already replaced is not offered as the one a new contract replaces" do
    @phone.update!(replaced_by: @insurance)

    post contracts_url, params: { contract: { name: "Another phone", kind: "mobile", predecessor_id: @phone.id } }

    assert_response :unprocessable_entity
    assert_equal @insurance, @phone.reload.replaced_by
  end

  test "document links keep their role" do
    patch contract_url(@insurance), params: { contract: { document_links: { "0" => { url: "https://paperless.example.com/documents/7", label: "AVB", role: "terms" } } } }

    assert_equal [ { "url" => "https://paperless.example.com/documents/7", "label" => "AVB", "role" => "terms" } ], @insurance.reload.document_links
  end

  test "show lists the price changes of the linked bills" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    netflix.recurring_price_changes.create!(effective_on: 1.month.ago.to_date, previous_amount: 12.99,
                                            new_amount: 15.99, currency: "USD", source: "detected")

    get contract_url(@phone)

    assert_response :success
    assert_select "p", text: I18n.t("contracts.show.price_changes")
    assert_match "$12.99 → $15.99", response.body
  end

  test "show states the next payment and the payments of the last year" do
    netflix = recurring_transactions(:netflix_subscription)
    netflix.update!(contract: @phone)
    occurrence = netflix.recurring_occurrences.create!(family: @family, original_due_on: 2.months.ago.to_date,
                                                       due_on: 2.months.ago.to_date, currency: "USD")
    entry = accounts(:depository).entries.create!(date: 2.months.ago.to_date, amount: 15.99, currency: "USD",
                                                  name: "NETFLIX.COM", entryable: Transaction.new)
    occurrence.allocations.create!(entry: entry, allocated_amount: 15.99, currency: "USD",
                                   state: "confirmed", source: "user_confirmed")
    occurrence.allocations.create!(allocated_amount: 3.21, currency: "USD", paid_on: 14.months.ago.to_date,
                                   state: "confirmed", source: "user_created")

    get contract_url(@phone)

    assert_response :success
    assert_includes response.body, I18n.t("contracts.show.next_payment")
    assert_includes response.body, I18n.l(netflix.next_due_date, format: :long)
    assert_includes response.body, I18n.t("contracts.show.payment_history", months: 12)
    assert_select "a[href=?]", entry_path(entry), text: /NETFLIX\.COM.*#{accounts(:depository).name}/m
    assert_not_includes response.body, "$3.21"
    assert_select "a[href=?]", contract_path(@phone, payments: "all", anchor: "contract-payment-history")

    get contract_url(@phone, payments: "all")

    assert_response :success
    assert_includes response.body, I18n.t("contracts.show.payment_history_all")
    assert_includes response.body, "$3.21"
    assert_select "a[href=?]", contract_path(@phone, anchor: "contract-payment-history")
  end

  test "show leaves out the payment sections without linked payments" do
    get contract_url(@insurance)

    assert_response :success
    assert_not_includes response.body, I18n.t("contracts.show.next_payment")
    assert_not_includes response.body, I18n.t("contracts.show.payment_history", months: 12)
  end

  test "index only shows contracts owned by or shared with the user" do
    sign_in @member

    get contracts_url

    assert_response :success
    assert_select "a[href=?]", contract_path(@phone)
    assert_select "a[href=?]", contract_path(@insurance), count: 0
  end

  test "admins do not see contracts that are not shared with them" do
    private_contract = @family.contracts.create!(name: "Bike insurance", owner: @member)
    private_contract.contract_shares.delete_all

    get contract_url(private_contract)

    assert_response :not_found
  end

  test "show renders full numbers for editors" do
    get contract_url(@phone)

    assert_response :success
    assert_includes response.body, "MOB-99887766"
    assert_includes response.body, "K-123456"
  end

  test "show states the notice deadline" do
    travel_to Date.new(2026, 9, 1) do
      get contract_url(@insurance)

      assert_includes response.body, I18n.l(Date.new(2026, 9, 30), format: :long)
      assert_includes response.body, I18n.t("contracts.show.notice_deadline")
    end
  end

  test "read-only shares see masked numbers only" do
    sign_in @member

    get contract_url(@phone)

    assert_response :success
    assert_not_includes response.body, "MOB-99887766"
    assert_not_includes response.body, "K-123456"
    assert_includes response.body, "•••• 7766"
  end

  test "read-only shares cannot edit or delete" do
    sign_in @member

    get edit_contract_url(@phone)
    assert_response :not_found

    patch contract_url(@phone), params: { contract: { name: "Hijacked" } }
    assert_response :not_found

    delete contract_url(@phone)
    assert_response :not_found
    assert_equal "Phone plan", @phone.reload.name
  end

  test "read-write shares can edit but not delete" do
    contract_shares(:phone_plan_shared_with_member).update!(permission: "read_write")
    sign_in @member

    patch contract_url(@phone), params: { contract: { notes: "Ask for a loyalty discount" } }
    assert_redirected_to contract_url(@phone)
    assert_equal "Ask for a loyalty discount", @phone.reload.notes

    delete contract_url(@phone)
    assert_response :not_found
  end

  test "creates a contract owned by the current user and links bills" do
    bill = recurring_transactions(:netflix_subscription)

    assert_difference -> { @family.contracts.count }, 1 do
      post contracts_url, params: {
        contract: {
          name: "Home contents",
          kind: "insurance",
          contract_number: "HR-1",
          notice_period_value: 3,
          notice_period_unit: "months",
          notice_anchor: "end_of_term",
          document_links: { "0" => { url: "https://paperless.example.com/documents/7", label: "Policy" }, "1" => { url: "", label: "" } },
          recurring_transaction_ids: [ bill.id, "" ]
        }
      }
    end

    contract = @family.contracts.order(:created_at).last
    assert_redirected_to contract_url(contract)
    assert_equal @admin, contract.owner
    assert_equal "HR-1", contract.contract_number
    assert_equal [ { "url" => "https://paperless.example.com/documents/7", "label" => "Policy" } ], contract.document_links
    assert_equal contract, bill.reload.contract
  end

  test "saves kind-specific details" do
    patch contract_url(@insurance), params: { contract: { details: { insurance_line: "liability", sum_insured: "5000000" } } }

    assert_redirected_to contract_url(@insurance)
    assert_equal({ "insurance_line" => "liability", "sum_insured" => "5000000" }, @insurance.reload.details)

    get contract_url(@insurance)
    assert_includes response.body, I18n.t("contracts.insurance_lines.liability")
  end

  test "overview prints open contracts with numbers always masked" do
    get overview_contracts_url(numbers: 1)

    assert_response :success
    assert_includes response.body, @insurance.name
    assert_includes response.body, "•••• 4711"
    assert_not_includes response.body, "LV-2024-004711"
  end

  test "overview never reveals numbers to a read-only share" do
    sign_in @member

    get overview_contracts_url(numbers: 1)

    assert_response :success
    assert_includes response.body, @phone.name
    assert_not_includes response.body, "MOB-99887766"
    assert_not_includes response.body, @insurance.name
  end

  test "an account page lists the contracts tied to it that the viewer can see" do
    @insurance.update!(account: accounts(:vehicle))

    get account_url(accounts(:vehicle), tab: "contracts")

    assert_response :success
    assert_select "a[href=?]", contract_path(@insurance)
  end

  test "reports show fixed costs and contracts" do
    recurring_transactions(:netflix_subscription).update!(contract: @phone)

    get reports_url

    assert_response :success
    assert_includes response.body, CGI.escapeHTML(I18n.t("reports.contracts.title"))
  end

  test "creating from a contract document prefills the form and attaches the PDF" do
    pdf_import = @family.imports.create!(type: "PdfImport", document_type: "contract",
                                         extracted_data: { "contract" => { "name" => "Home contents", "provider" => "Allianz", "kind" => "insurance" } })
    pdf_import.pdf_file.attach(io: StringIO.new("%PDF-1.4 policy"), filename: "policy.pdf", content_type: "application/pdf")

    get new_contract_url(pdf_import_id: pdf_import.id)
    assert_response :success
    assert_select "input[name='contract[name]'][value=?]", "Home contents"
    assert_select "input[name='contract[pdf_import_id]'][value=?]", pdf_import.id
    assert_includes response.body, ERB::Util.html_escape(I18n.t("contracts.form.suggested_merchant", name: "Allianz")),
                    "no merchant matches, so the form names the provider to add"

    post contracts_url, params: { contract: { name: "Home contents", kind: "insurance", pdf_import_id: pdf_import.id } }

    contract = @family.contracts.find_by!(name: "Home contents")
    assert_equal [ "policy.pdf" ], contract.contract_documents.map { |document| document.file.filename.to_s }
  end

  test "a document's provider picks the matching merchant" do
    pdf_import = @family.imports.create!(type: "PdfImport", document_type: "contract",
                                         extracted_data: { "contract" => { "name" => "Streaming", "provider" => "NETFLIX", "kind" => "streaming" } })

    get new_contract_url(pdf_import_id: pdf_import.id)

    assert_select "input[type=hidden][name='contract[merchant_id]'][value=?]", merchants(:netflix).id
  end

  test "saving the form keeps an account and successor the editor cannot see" do
    @phone.update!(account: accounts(:loan), replaced_by: @insurance) # neither is visible to the member
    contract_shares(:phone_plan_shared_with_member).update!(permission: "read_write")
    sign_in @member

    patch contract_url(@phone), params: { contract: { notes: "Only the notes", account_id: "", replaced_by_id: "" } }

    assert_redirected_to contract_url(@phone)
    @phone.reload
    assert_equal accounts(:loan), @phone.account
    assert_equal @insurance, @phone.replaced_by
    assert_equal "Only the notes", @phone.notes
  end

  test "the index names a related account only to users who can see it" do
    @phone.update!(account: accounts(:loan)) # not shared with the member

    get contracts_url
    assert_includes response.body, accounts(:loan).name

    sign_in @member
    get contracts_url
    assert_not_includes response.body, accounts(:loan).name
  end

  test "linking bills leaves a bill held by a contract the editor cannot edit" do
    bill = recurring_transactions(:netflix_subscription) # on an account the member may write
    bill.update!(contract: @insurance) # the admin's contract, not shared with the member
    contract_shares(:phone_plan_shared_with_member).update!(permission: "read_write")
    sign_in @member

    patch contract_url(@phone), params: { contract: { name: "Phone plan", recurring_transaction_ids: [ bill.id ] } }

    assert_equal @insurance, bill.reload.contract
  end

  test "rejects related records the user cannot reach" do
    other_account = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)

    assert_no_difference -> { Contract.count } do
      post contracts_url, params: { contract: { name: "Sneaky", account_id: other_account.id } }
    end

    assert_response :unprocessable_entity
  end

  test "update unlinks deselected bills but leaves bills the user cannot change" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    patch contract_url(@phone), params: { contract: { name: "Phone plan", recurring_transaction_ids: [ "" ] } }

    assert_nil bill.reload.contract_id
  end

  test "new prefills from a bill" do
    bill = recurring_transactions(:netflix_subscription)

    get new_contract_url(recurring_transaction_id: bill.id)

    assert_response :success
    assert_select "input[name='contract[name]'][value=?]", bill.display_name
    assert_select "input[type=checkbox][value=?][checked]", bill.id
  end

  test "owner can delete and the bills stay" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    delete contract_url(@phone)

    assert_redirected_to contracts_url
    assert_not Contract.exists?(@phone.id)
    assert RecurringTransaction.exists?(bill.id)
  end

  test "the payments dialog lists linkable bills and ticks the merchant's while none are linked" do
    @phone.update!(merchant: merchants(:netflix))
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(merchant: merchants(:netflix), contract: nil)

    get payments_contract_url(@phone)

    assert_response :success
    assert_select "input[type=checkbox][name='contract[recurring_transaction_ids][]'][value='#{bill.id}'][checked]"

    patch contract_url(@phone), params: { contract: { recurring_transaction_ids: [ bill.id, "" ] } }
    assert_equal @phone, bill.reload.contract
  end

  test "adding a payment from a contract links the new bill and returns to the contract" do
    assert_difference -> { @phone.recurring_transactions.count }, 1 do
      post recurring_transactions_url, params: {
        contract_id: @phone.id,
        recurring_transaction: { name: "Phone bill", amount: "29.99", account_id: accounts(:depository).id,
                                 first_due_on: Date.current.iso8601, frequency_preset: "monthly" }
      }
    end

    assert_redirected_to contract_url(@phone)
  end

  test "adding a payment for a contract the user cannot edit saves the bill unlinked" do
    sign_in @member

    post recurring_transactions_url, params: {
      contract_id: @phone.id,
      recurring_transaction: { name: "Phone bill", amount: "29.99", account_id: accounts(:depository).id,
                               first_due_on: Date.current.iso8601, frequency_preset: "monthly" }
    }

    assert_redirected_to bills_url
    assert_not @phone.recurring_transactions.exists?(name: "Phone bill")
  end

  test "the form offers merchants from the user's transactions and can pick one" do
    get edit_contract_url(@phone)
    assert_select "[data-controller='merchant-select']"

    patch contract_url(@phone), params: { contract: { merchant_id: merchants(:amazon).id } }
    assert_equal merchants(:amazon), @phone.reload.merchant
  end

  test "a contract billed in a currency without exchange rate shows its cost in that currency" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone, currency: "EUR")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    expected = ActionController::Base.helpers.strip_tags(
      ApplicationController.helpers.format_money(bill.monthly_equivalent_amount.abs * 12)
    )
    zero = ActionController::Base.helpers.strip_tags(ApplicationController.helpers.format_money(Money.new(0, "USD")))

    [ contracts_url, contract_url(@phone), overview_contracts_url ].each do |url|
      get url

      assert_response :success
      assert_includes response.body, expected, url
    end

    get contract_url(@phone)
    assert_not_includes response.body, zero

    get contracts_url
    monthly = ActionController::Base.helpers.strip_tags(
      ApplicationController.helpers.format_money(bill.monthly_equivalent_amount.abs * 12 / 12)
    )
    assert_includes response.body, monthly
    assert_not_includes response.body, zero
  end

  test "the printed overview shows cost, deadline, owner and paying account" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)
    cost, = @phone.annual_cost_for(@admin)

    get overview_contracts_url

    assert_response :success
    assert_includes response.body, ERB::Util.html_escape(@admin.display_name)
    assert_includes response.body, ERB::Util.html_escape(bill.account.name)
    assert_includes response.body, ActionController::Base.helpers.strip_tags(ApplicationController.helpers.format_money(cost))
  end

  test "index and show are localized in German" do
    @admin.update!(locale: "de")

    get contracts_url
    assert_select "main h1", text: "Verträge"

    get contract_url(@insurance)
    assert_includes response.body, "Kündigungsfrist"
    assert_includes response.body, "Letzter Kündigungstag"
  end

  private

    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end
end
