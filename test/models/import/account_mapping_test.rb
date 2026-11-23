require "test_helper"

class Import::AccountMappingTest < ActiveSupport::TestCase
  setup do
    @import = imports(:transaction)
    @mapping = @import.mappings.create!(key: "Checking", type: "Import::AccountMapping")
  end

  test "selectable_values offers linked accounts the user can write to" do
    ids = @mapping.selectable_values(user: users(:family_admin)).map(&:last)

    assert_includes ids, accounts(:connected).id
    assert_includes ids, accounts(:depository).id
  end

  test "selectable_values offers only accounts the user can write to" do
    ids = @mapping.selectable_values(user: users(:family_member)).map(&:last)

    assert_includes ids, accounts(:depository).id
    assert_not_includes ids, accounts(:credit_card).id
    assert_not_includes ids, accounts(:connected).id
  end

  test "selectable_values leaves out accounts that are not visible" do
    accounts(:connected).disable!

    ids = @mapping.selectable_values(user: users(:family_admin)).map(&:last)

    assert_not_includes ids, accounts(:connected).id
  end

  test "selectable_values offers no accounts without a user" do
    assert_equal [ [ "Add as new account", Import::Mapping::CREATE_NEW_KEY ] ], @mapping.selectable_values(user: nil)
  end
end
