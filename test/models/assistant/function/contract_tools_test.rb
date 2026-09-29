require "test_helper"

class Assistant::Function::ContractToolsTest < ActiveSupport::TestCase
  NUMBERS = %w[LV-2024-004711 MOB-99887766 K-123456].freeze

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @insurance = contracts(:liability_insurance)
    @phone = contracts(:phone_plan)
    @phone.update!(notes: "Customer number K-123456", details: { "tariff" => "Unlimited", "phone_number" => "+49 170 1234567" })
  end

  teardown do
    travel_back
  end

  test "no tool ever returns a contract or customer number, notes or personal details" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)

    outputs = [
      call(Assistant::Function::GetContracts, @admin),
      call(Assistant::Function::GetContractDetails, @admin, "contract_id" => @phone.id),
      call(Assistant::Function::GetContractDetails, @admin, "contract_id" => @insurance.id),
      call(Assistant::Function::GetContractAudit, @admin),
      call(Assistant::Function::GetCancellationLetter, @admin, "contract_id" => @phone.id),
      call(Assistant::Function::UpdateContract, @admin, "contract_id" => @phone.id, "name" => "Phone plan")
    ].map(&:to_json)

    outputs.each do |json|
      NUMBERS.each { |number| assert_not_includes json, number }
      assert_not_includes json, "+49 170 1234567"
    end
  end

  test "get_contracts lists only contracts the user can see" do
    names = call(Assistant::Function::GetContracts, @member)[:contracts].map { |c| c[:name] }

    assert_includes names, @phone.name
    assert_not_includes names, @insurance.name
  end

  test "get_contracts reports the notice deadline" do
    travel_to Date.new(2026, 9, 1)

    contract = call(Assistant::Function::GetContracts, @admin)[:contracts].find { |c| c[:id] == @insurance.id }

    assert_equal "2026-09-30", contract[:notice_deadline]
    assert_equal "2026-12-31", contract[:term_ends_on]
  end

  test "details of a contract the user cannot see are not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      call(Assistant::Function::GetContractDetails, @member, "contract_id" => @insurance.id)
    end
  end

  test "create_contract records a contract owned by the user and links writable bills" do
    bill = recurring_transactions(:netflix_subscription)

    result = call(Assistant::Function::CreateContract, @admin,
                  "name" => "Gym", "provider" => "FitX", "kind" => "fitness",
                  "minimum_term_months" => 12, "notice_period_value" => 1, "notice_period_unit" => "months",
                  "notice_anchor" => "any_day", "started_on" => "2026-01-01", "bill_ids" => [ bill.id ])

    contract = @admin.family.contracts.find(result[:contract][:id])
    assert_equal @admin, contract.owner
    assert_equal contract, bill.reload.contract
    assert_equal [ bill.display_name ], result[:linked_bills]
  end

  test "create_contract does not take a bill from a contract the user cannot edit" do
    bill = recurring_transactions(:netflix_subscription) # on an account the member may write
    bill.update!(contract: @insurance) # the admin's contract, not shared with the member

    result = call(Assistant::Function::CreateContract, @member,
                  "name" => "Streaming", "provider" => "Netflix", "kind" => "streaming", "bill_ids" => [ bill.id ])

    assert_equal @insurance, bill.reload.contract
    assert_empty result[:linked_bills]
  end

  test "the related account is named only to users who can see that account" do
    @phone.update!(account: accounts(:loan)) # not shared with the member

    member_view = call(Assistant::Function::GetContracts, @member)[:contracts].find { |c| c[:id] == @phone.id }
    admin_view = call(Assistant::Function::GetContracts, @admin)[:contracts].find { |c| c[:id] == @phone.id }

    assert_nil member_view[:related_account]
    assert_equal accounts(:loan).name, admin_view[:related_account]
  end

  test "create_contract saves nothing when a bill fails to link" do
    bill = recurring_transactions(:netflix_subscription)
    RecurringTransaction.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(bill))

    result = nil
    assert_no_difference -> { Contract.count } do
      result = call(Assistant::Function::CreateContract, @admin,
                    "name" => "Streaming", "provider" => "Netflix", "kind" => "streaming", "bill_ids" => [ bill.id ])
    end

    assert result[:error].present?
    assert_nil bill.reload.contract_id
  end

  test "update_contract refuses a read-only share" do
    result = call(Assistant::Function::UpdateContract, @member, "contract_id" => @phone.id, "name" => "Hijacked")

    assert result[:error].present?
    assert_equal "Phone plan", @phone.reload.name
  end

  test "update_contract rejects a malformed date instead of clearing the stored one" do
    @phone.update!(ends_on: Date.new(2027, 2, 28))

    result = call(Assistant::Function::UpdateContract, @admin, "contract_id" => @phone.id, "ends_on" => "2027-13-45")

    assert_includes result[:error], "ends_on"
    assert_equal Date.new(2027, 2, 28), @phone.reload.ends_on

    result = call(Assistant::Function::UpdateContract, @admin, "contract_id" => @phone.id, "ends_on" => "")
    assert_nil result[:error]
    assert_nil @phone.reload.ends_on, "an explicit empty string still clears the date"
  end

  test "the cancellation letter is a link, never the letter" do
    result = call(Assistant::Function::GetCancellationLetter, @admin, "contract_id" => @phone.id)

    assert_equal Rails.application.routes.url_helpers.cancellation_letter_contract_path(@phone), result[:url]
  end

  test "the audit finds upcoming deadlines and unconfirmed cancellations" do
    travel_to Date.new(2026, 9, 1)
    @phone.update!(status: "cancellation_sent", cancelled_on: Date.new(2026, 8, 1))

    result = call(Assistant::Function::GetContractAudit, @admin)

    assert result[:upcoming_deadlines].any? { |row| row[:id] == @insurance.id }
    assert result[:unconfirmed_cancellations].any? { |row| row[:id] == @phone.id }
  end

  test "contract tools respect the family's bills switch" do
    @admin.family.update!(recurring_transactions_disabled: true)

    assert call(Assistant::Function::GetContracts, @admin)[:error].present?
  end

  test "contract tools are registered for preview users only" do
    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
    assert_includes Assistant.function_classes(@admin), Assistant::Function::GetContracts

    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))
    assert_not_includes Assistant.function_classes(@admin), Assistant::Function::GetContracts
  end

  private

    def call(klass, user, params = {})
      klass.new(user).call(params)
    end
end
