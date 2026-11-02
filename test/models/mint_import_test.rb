require "test_helper"

class MintImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "MintImport")

    MintImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end

  test "generated rows preserve stable source row numbers" do
    import = @family.imports.create!(
      type: "MintImport",
      raw_file_str: file_fixture("imports/mint.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv

    assert_equal (1..10).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
  end

  test "new accounts get the account type chosen in the mapping step" do
    import = @family.imports.create!(
      type: "MintImport",
      raw_file_str: <<~CSV,
        Date,Description,Original Description,Amount,Transaction Type,Category,Account Name,Labels,Notes
        05/01/2023,Grocery Store,SAFEWAY,78.32,debit,,Everyday Checking,,
        05/02/2023,Gas Station,SHELL,45.67,debit,,Sapphire Visa,,
        05/03/2023,Coffee,STARBUCKS,4.50,debit,,Rewards Plus,,
        05/04/2023,Rent,RENT,900.00,debit,,Checking Account,,
      CSV
      col_sep: ","
    )
    import.generate_rows_from_csv
    import.sync_mappings

    type_mappings = import.mappings.new_account_types.index_by(&:key)
    assert_equal [ "Everyday Checking", "Rewards Plus", "Sapphire Visa" ], type_mappings.keys.sort
    assert_equal "Depository", type_mappings["Everyday Checking"].value
    assert_equal "CreditCard", type_mappings["Sapphire Visa"].value

    type_mappings["Rewards Plus"].update!(value: "CreditCard")
    import.reload

    assert import.publishable?
    import.import!

    assert_instance_of Depository, @family.accounts.find_by!(name: "Everyday Checking").accountable
    sapphire = @family.accounts.find_by!(name: "Sapphire Visa")
    assert_instance_of CreditCard, sapphire.accountable
    assert_equal "liability", sapphire.classification
    assert_instance_of CreditCard, @family.accounts.find_by!(name: "Rewards Plus").accountable
    assert_equal 1, @family.accounts.where(name: "Checking Account").count
  end

  test "keeps the chosen account type when mappings are synced again" do
    import = @family.imports.create!(
      type: "MintImport",
      raw_file_str: "Date,Description,Amount,Transaction Type,Account Name\n05/01/2023,Coffee,4.50,debit,Rewards Plus\n",
      col_sep: ","
    )
    import.generate_rows_from_csv
    import.sync_mappings
    import.mappings.new_account_types.find_by!(key: "Rewards Plus").update!(value: "CreditCard")

    import.sync_mappings

    assert_equal "CreditCard", import.mappings.new_account_types.find_by!(key: "Rewards Plus").value
  end

  test "falls back to the name suggestion when no type mapping exists" do
    import = @family.imports.create!(type: "MintImport")

    assert_equal "CreditCard", import.account_type_for_new_account("Sapphire Visa")
    assert_equal "Depository", import.account_type_for_new_account("Everyday Checking")
  end
end
