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

        assert_equal "Starbucks", name_input.value
        assert_category categories(:food_and_drink)
        assert_equal name_input, page.active_element, "picking a name moved focus out of the name field"

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

    within all("[data-split-transaction-target='row']", minimum: 2).first do
      assert_equal "Starbucks", find("input[role='combobox']").value
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

        assert_equal "Starbucks", name_input.value
        assert_category categories(:income)
      end
    end
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
