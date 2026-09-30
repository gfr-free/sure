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

  test "index only shows contracts owned by or shared with the user" do
    sign_in @member

    get contracts_url

    assert_response :success
    assert_select "a[href=?]", contract_path(@phone)
    assert_select "a[href=?]", contract_path(@insurance), count: 0
  end

  test "admins do not see contracts that are not shared with them" do
    private_contract = @family.contracts.create!(name: "Bike insurance", provider_name: "Insurer", owner: @member)
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
          provider_name: "Allianz",
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

  test "overview prints open contracts with masked numbers unless asked" do
    get overview_contracts_url

    assert_response :success
    assert_includes response.body, @insurance.name
    assert_includes response.body, "•••• 4711"
    assert_not_includes response.body, "LV-2024-004711"

    get overview_contracts_url(numbers: 1)
    assert_includes response.body, "LV-2024-004711"
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

    post contracts_url, params: { contract: { name: "Home contents", provider_name: "Allianz", kind: "insurance", pdf_import_id: pdf_import.id } }

    contract = @family.contracts.find_by!(name: "Home contents")
    assert_equal [ "policy.pdf" ], contract.contract_documents.map { |document| document.file.filename.to_s }
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
      post contracts_url, params: { contract: { name: "Sneaky", provider_name: "X", account_id: other_account.id } }
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

  test "mark ended" do
    patch mark_ended_contract_url(@insurance)

    assert_redirected_to contract_url(@insurance)
    assert @insurance.reload.ended?
    assert_equal Date.current, @insurance.ends_on
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
