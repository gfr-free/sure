require "test_helper"

class ContractShareTest < ActiveSupport::TestCase
  setup do
    @contract = contracts(:liability_insurance)
  end

  test "cannot share with the owner" do
    share = @contract.contract_shares.new(user: users(:family_admin), permission: "read_only")

    assert_not share.valid?
    assert share.errors.added?(:user, :owner)
  end

  test "cannot share outside the family" do
    share = @contract.contract_shares.new(user: users(:empty), permission: "read_only")

    assert_not share.valid?
    assert share.errors.added?(:user, :other_family)
  end

  test "guests can only read" do
    guest = families(:dylan_family).users.create!(email: "guest@example.com", password: "password123!", role: "guest")
    share = @contract.contract_shares.new(user: guest, permission: "read_write")

    assert_not share.valid?
    assert share.errors.added?(:permission, :guest_read_only)

    share.permission = "read_only"
    assert share.valid?
  end

  test "one share per member" do
    duplicate = contracts(:phone_plan).contract_shares.new(user: users(:family_member), permission: "read_only")

    assert_not duplicate.valid?
  end
end
