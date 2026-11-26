require "application_system_test_case"

class SplitsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = create_transaction(amount: 100, name: "Split layout", account: accounts(:depository))
    @entry.split!([ { name: "Groceries", amount: 70 }, { name: "Household", amount: 30 } ])
  end

  test "edit dialog keeps each split row's category, merchant and tag pickers inside the row" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      rows = all("[data-split-transaction-target='row']", minimum: 2)

      rows.each do |row|
        overflow = page.evaluate_script("arguments[0].scrollWidth - arguments[0].clientWidth", row)
        assert_operator overflow, :<=, 0, "split row content overflows its row by #{overflow}px"
      end
    end
  end

  test "edit dialog saves the merchant and tags picked with the DS pickers" do
    merchant = @user.family.merchants.create!(name: "Split Grocer")

    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        find("[data-merchant-select-target='button']").click
        find("[role='option'][data-merchant-name='#{merchant.name}']").click
        find("[data-tag-select-target='button']").click
        find("[role='option'][data-tag-name='#{tags(:one).name}']").click
      end

      click_button I18n.t("splits.edit.submit")
    end

    assert_text I18n.t("splits.update.success")

    child = @entry.reload.child_entries.find_by!(name: "Groceries")
    assert_equal merchant.id, child.entryable.merchant_id
    assert_equal [ tags(:one).id ], child.entryable.tag_ids
  end

  test "tag picker in a split row stays as tall as the other pickers" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        assert_equal 1, picker_heights.uniq.size, "empty tag picker height differs: #{picker_heights}"

        find("[data-tag-select-target='button']").click
        find("[role='option'][data-tag-name='#{tags(:one).name}']").click
        find("[data-tag-select-target='selectionContainer']", text: tags(:one).name)

        assert_equal 1, picker_heights.uniq.size, "tag picker with a tag differs: #{picker_heights}"
      end
    end
  end

  test "a new split row starts with the remaining amount" do
    entry = create_transaction(amount: 100, name: "Prefill remaining", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      amount_fields = -> { all("[data-split-transaction-target='amountInput']") }

      assert_equal "", amount_fields.call.first.value
      amount_fields.call.first.fill_in with: "-30"

      click_button I18n.t("splits.new.add_row")

      assert_equal 2, amount_fields.call.size
      assert_equal "-70.00", amount_fields.call.last.value
      assert_selector "[data-split-transaction-target='remaining']", text: "0.00"
      assert_not find("button[type='submit']").disabled?
    end
  end

  test "a new split row stays empty when nothing is left to assign" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      click_button I18n.t("splits.new.add_row")

      amount_fields = all("[data-split-transaction-target='amountInput']", minimum: 3)
      assert_equal "", amount_fields.last.value
    end
  end

  test "the newest split row follows changes to the other amounts until it is edited" do
    entry = create_transaction(amount: 100, name: "Prefill follows", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      amount_fields = -> { all("[data-split-transaction-target='amountInput']") }

      click_button I18n.t("splits.new.add_row")
      assert_equal "-100.00", amount_fields.call.last.value

      amount_fields.call.first.fill_in with: "-30"
      assert_equal "-70.00", amount_fields.call.last.value

      amount_fields.call.last.fill_in with: "-60"
      amount_fields.call.first.fill_in with: "-20"
      assert_equal(-60, amount_fields.call.last.value.to_d)
      assert_selector "[data-split-transaction-target='remaining']", text: "-20.00"
    end
  end

  test "the following split row empties instead of taking the opposite sign" do
    entry = create_transaction(amount: 100, name: "Prefill overshoot", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      amount_fields = -> { all("[data-split-transaction-target='amountInput']") }

      amount_fields.call.first.fill_in with: "-30"
      click_button I18n.t("splits.new.add_row")

      amount_fields.call.first.fill_in with: "-120"
      assert_equal "", amount_fields.call.last.value
      assert_selector "[data-split-transaction-target='remaining']", text: "20.00"

      amount_fields.call.first.fill_in with: "-90"
      assert_equal "-10.00", amount_fields.call.last.value
    end
  end

  test "a following split row stops following once its text is changed without an input event" do
    entry = create_transaction(amount: 100, name: "Prefill replaced", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      amount_fields = -> { all("[data-split-transaction-target='amountInput']") }

      amount_fields.call.first.fill_in with: "-30"
      click_button I18n.t("splits.new.add_row")
      execute_script("arguments[0].value = '-55'", amount_fields.call.last)

      amount_fields.call.first.fill_in with: "-20"
      assert_equal "-55", amount_fields.call.last.value
    end
  end

  private
    # Heights of the category, merchant and tag fields in the current split row.
    def picker_heights
      evaluate_script(<<~JS, current_scope)
        Array.from(arguments[0].querySelectorAll(".grid .form-field")).map((field) => Math.round(field.getBoundingClientRect().height))
      JS
    end
end
