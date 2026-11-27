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

  test "picking a past name in a new split row sets that name's usual category" do
    entry = create_transaction(amount: 50, name: "Split suggestions", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      click_button I18n.t("splits.new.add_row")
      row = all("[data-split-transaction-target='row']", count: 2).last

      within row do
        name_input = find("input[role='combobox']")
        name_input.fill_in with: "Starb"
        assert_selector ".hw-combobox [role='option']", text: "Starbucks"
        name_input.send_keys(:arrow_down, :enter)

        assert_field with: "Starbucks"
        assert_category categories(:food_and_drink)
        assert_selector "input[role='combobox']:focus"

        find("input[name$='[amount]']").fill_in with: "-20"
      end

      first_row = all("[data-split-transaction-target='row']", count: 2).first
      within(first_row) { find("input[name$='[amount]']").fill_in with: "-30" }
      assert_category nil, scope: first_row

      click_button I18n.t("splits.new.submit")
    end

    assert_text I18n.t("splits.create.success")

    children = entry.reload.child_entries.index_by(&:name)
    assert_equal [ "Split suggestions", "Starbucks" ], children.keys.sort
    assert_equal categories(:food_and_drink), children["Starbucks"].entryable.category
    assert_nil children["Split suggestions"].entryable.category
  end

  test "opening and leaving a prefilled split name does not apply a category" do
    create_transaction(amount: 12, name: "Groceries", account: accounts(:depository), category: categories(:food_and_drink))

    # Opened from the transaction drawer, the way users reach it: the dialog is loaded into
    # the modal frame after the page's controllers are running.
    visit transaction_path(@entry)
    click_on I18n.t("splits.child.edit_split")

    within "turbo-frame#modal dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        # Typing and removing a character loads the list without changing the name.
        find("input[role='combobox']").send_keys(:end, "x", :backspace)
        assert_selector ".hw-combobox [role='option']", text: "Groceries"
      end

      find("h2", text: @entry.name).click
      assert_no_selector ".hw-combobox [role='option']"

      within all("[data-split-transaction-target='row']", minimum: 2).first do
        assert_field with: "Groceries"
        assert_category nil
      end
    end
  end

  test "split rows save the visible name even if a late suggestion changes the hidden field" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        find("input[role='combobox']").fill_in with: "Typed name"
        # Stands in for an async suggestion response that lands after the user typed.
        execute_script("arguments[0].value = 'Late suggestion'", find("[data-hw-combobox-target='hiddenField']", visible: :all))
      end

      click_button I18n.t("splits.edit.submit")
    end

    # Waits on the saved row, not the flash: the combobox's own suggestion request
    # can land between the save and its redirect and use up the flash.
    assert_no_selector "dialog[open]"
    assert_text "Typed name"
    assert_equal [ "Household", "Typed name" ], @entry.reload.child_entries.map(&:name).sort
  end

  test "mobile name picker in a split row sets the usual category" do
    page.current_window.resize_to(390, 844)
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within(all("[data-split-transaction-target='row']", minimum: 2).first) { find("input[role='combobox']").click }
    end

    within "dialog.hw-combobox__dialog[open]" do
      find("input[role='combobox']").set("Starb")
      find("[role='option']", text: "Starbucks").click
    end

    assert_no_selector "dialog.hw-combobox__dialog[open]"

    within all("[data-split-transaction-target='row']", minimum: 2).first do
      assert_field with: "Starbucks"
      assert_category categories(:food_and_drink)
    end
  end

  test "a category already chosen in a split row is not replaced by a picked name" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        find(".category-select-container [data-select-target='button']").click
        find(".category-select-container [role='option'][data-value='#{categories(:income).id}']").click

        name_input = find("input[role='combobox']")
        name_input.fill_in with: "Starb"
        assert_selector ".hw-combobox [role='option']", text: "Starbucks"
        name_input.send_keys(:arrow_down, :enter)

        assert_field with: "Starbucks"
        assert_category categories(:income)
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

  test "split dialog shows the category and merchant name a blank row will get" do
    @user.family.update!(auto_generate_transaction_names: true)
    entry = create_transaction(amount: 50, name: "Corner shop", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      name_input = find("input[name='split[splits][0][name]']")
      assert_equal "Corner shop", name_input[:placeholder]

      within find("[data-split-transaction-target='row']") do
        find("[data-merchant-select-target='button']").click
        find("[role='option'][data-merchant-name='Netflix']").click
      end

      assert_equal "Netflix", name_input[:placeholder]

      within find("[data-split-transaction-target='row']") do
        find(".category-select-container button[data-select-target='button']").click
        find(".category-select-container [role='option'][data-value='#{categories(:food_and_drink).id}']").click
      end

      assert_equal "Food & Drink - Netflix", name_input[:placeholder]

      click_button I18n.t("splits.new.add_row")
      added = all("input[data-split-transaction-target='nameInput']").last
      assert_equal "Corner shop", added[:placeholder]

      name_input.fill_in with: ""
      find("input[name='split[splits][0][amount]']").fill_in with: (-entry.amount).to_s
      added_row = all("[data-split-transaction-target='row']").last
      added_row.find("[aria-label='#{I18n.t("splits.new.remove_row")}']").click

      click_button I18n.t("splits.new.submit")
    end

    assert_text I18n.t("splits.create.success")
    assert_equal [ "Food & Drink - Netflix" ], entry.reload.child_entries.pluck(:name)
  end

  private
    def assert_category(category, scope: current_scope)
      within(scope) do
        assert_selector(".category-select-container input[type='hidden']", visible: :all) { |input| input.value == category&.id.to_s }
      end
    end

    # Heights of the category, merchant and tag fields in the current split row.
    def picker_heights
      evaluate_script(<<~JS, current_scope)
        Array.from(arguments[0].querySelectorAll(".grid .form-field")).map((field) => Math.round(field.getBoundingClientRect().height))
      JS
    end
end
