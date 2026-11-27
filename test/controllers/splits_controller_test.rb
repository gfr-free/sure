require "test_helper"

class SplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = create_transaction(
      amount: 100,
      name: "Grocery Store",
      account: accounts(:depository)
    )
  end

  test "new renders split editor" do
    get new_transaction_split_path(@entry)
    assert_response :success
  end

  test "new groups subcategories immediately after their parent in the category selector" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    category_values = doc.css(".category-select-container [data-value]").map { |node| node["data-value"] }

    parent_index = category_values.index(categories(:food_and_drink).id)
    child_index = category_values.index(categories(:subcategory).id)

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "new gives each split row's pickers their own ids and labelled controls" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    ids = doc.css("[data-split-transaction-target='row'] [id]").map { |node| node["id"] }
    assert_empty ids.tally.select { |_id, count| count > 1 }.keys

    trigger = doc.at_css("#split_splits_0_category_id_trigger")
    assert_not_nil trigger
    assert_equal "split_splits_0_category_id_label split_splits_0_category_id_trigger", trigger["aria-labelledby"]

    %w[merchant_id tag_ids].each do |field|
      label = doc.at_css("label[for='split_splits_0_#{field}']")
      assert_not_nil label, "missing label for #{field}"
      assert_equal "button", doc.at_css("#split_splits_0_#{field}")&.name
    end
  end

  test "new offers past transaction names in every split row, like the transaction form" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    # The first row plus the template that added rows are cloned from.
    rows = doc.css("[data-split-transaction-target='row']")
    assert_equal 2, rows.size

    rows.each do |row|
      assert_equal "category-suggestion", row["data-controller"]
      assert_includes row["data-action"], "hw-combobox:selection->category-suggestion#onNameSuggestionSelected"
      assert_includes row.at_css(".hw-combobox")["data-hw-combobox-async-src-value"], name_suggestions_transactions_path

      input = row.at_css("input[role='combobox']")
      assert_equal "nameInput", input["data-split-transaction-target"]
      assert_equal "name", input["data-category-suggestion-target"]
      assert input.key?("required")
      assert_not_nil row.at_css(".category-select-container[data-category-suggestion-target='categoryField']")
    end

    assert_equal "Grocery Store", doc.at_css("input[name='split[splits][0][name]'][data-hw-combobox-target='hiddenField']")["value"]
  end

  test "new and edit forms wire formdata to syncNames" do
    get new_transaction_split_path(@entry)
    assert_select "form[data-controller~='split-transaction'][data-action~='formdata->split-transaction#syncNames']"

    @entry.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])
    get edit_transaction_split_path(@entry)
    assert_select "form[data-controller~='split-transaction'][data-action~='formdata->split-transaction#syncNames']"
  end

  test "create with valid params splits transaction" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: categories(:food_and_drink).id },
            { name: "Household", amount: "-30", category_id: "" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.create.success"), flash[:notice]
    assert @entry.reload.excluded?
    assert @entry.split_parent?
  end

  test "new leaves every split name blank when names are generated" do
    @user.family.update!(auto_generate_transaction_names: true)

    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    name_input = doc.at_css("input[name='split[splits][0][name]']")
    assert_not_nil name_input
    assert_nil name_input["value"]
    assert_nil name_input["required"]

    form = doc.at_css("form[data-controller='split-transaction']")
    assert_equal "true", form["data-split-transaction-generate-names-value"]
    assert_equal "Grocery Store", form["data-split-transaction-default-name-value"]
  end

  test "new requires split names and prefills the first with the parent's when names are not generated" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    name_input = doc.at_css("input[name='split[splits][0][name]']")
    assert_equal "Grocery Store", name_input["value"]
    assert_not_nil name_input["required"]
    assert_equal "false", doc.at_css("form[data-controller='split-transaction']")["data-split-transaction-generate-names-value"]
  end

  test "create rejects a blank split name when names are not generated" do
    assert_no_difference "Entry.count" do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "", amount: "-60", category_id: categories(:food_and_drink).id },
            { name: "Other", amount: "-40" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    assert flash[:alert].present?
    assert_not @entry.reload.split_parent?
  end

  test "create names a part left blank after its category and merchant" do
    @user.family.update!(auto_generate_transaction_names: true)

    post transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "", amount: "-70", category_id: categories(:food_and_drink).id, merchant_id: merchants(:amazon).id },
          { name: "", amount: "-20", category_id: categories(:food_and_drink).id },
          { name: " ", amount: "-10", merchant_id: merchants(:netflix).id }
        ]
      }
    }

    assert_redirected_to transactions_url
    assert_equal [ "Food & Drink - Amazon", "Food & Drink", "Netflix" ].sort, @entry.child_entries.pluck(:name).sort
  end

  test "create leaves a part's empty merchant empty and names the part without the parent's merchant" do
    @user.family.update!(auto_generate_transaction_names: true)
    @entry.entryable.update!(merchant: merchants(:netflix))

    post transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "", amount: "-60", category_id: categories(:food_and_drink).id },
          { name: "Kept", amount: "-40" }
        ]
      }
    }

    children = @entry.child_entries.in_split_order
    assert_equal [ "Food & Drink", "Kept" ], children.map(&:name)
    assert_equal [ nil, nil ], children.map { |child| child.entryable.merchant_id }
  end

  test "create gives a blank part without category or merchant the parent's name" do
    @user.family.update!(auto_generate_transaction_names: true)

    post transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "", amount: "-60" },
          { name: "Other", amount: "-40" }
        ]
      }
    }

    assert_equal [ "Grocery Store", "Other" ], @entry.child_entries.in_split_order.pluck(:name)
  end

  test "create does not name a part after another family's category" do
    @user.family.update!(auto_generate_transaction_names: true)
    foreign_category = families(:empty).categories.create!(name: "Foreign category")

    post transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "", amount: "-60", category_id: foreign_category.id },
          { name: "Other", amount: "-40" }
        ]
      }
    }

    assert_equal [ "Grocery Store", "Other" ], @entry.child_entries.in_split_order.pluck(:name)
  end

  test "create with mismatched amounts rejects" do
    assert_no_difference "Entry.count" do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Part 1", amount: "-60", category_id: "" },
            { name: "Part 2", amount: "-20", category_id: "" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    assert flash[:alert].present?
  end

  test "destroy unsplits transaction" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    assert_difference "Entry.count", -2 do
      delete transaction_split_path(@entry)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.destroy.success"), flash[:notice]
    refute @entry.reload.excluded?
  end

  test "create with income transaction applies correct sign" do
    income_entry = create_transaction(
      amount: -400,
      name: "Reimbursement",
      account: accounts(:depository)
    )

    assert_difference "Entry.count", 2 do
      post transaction_split_path(income_entry), params: {
        split: {
          splits: [
            { name: "Part 1", amount: "200", category_id: "" },
            { name: "Part 2", amount: "200", category_id: "" }
          ]
        }
      }
    end

    assert income_entry.reload.excluded?
    children = income_entry.child_entries
    assert_equal(-200, children.first.amount.to_i)
    assert_equal(-200, children.last.amount.to_i)
  end

  test "create with mixed sign amounts on expense" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Main expense", amount: "-130", category_id: "" },
            { name: "Refund", amount: "30", category_id: "" }
          ]
        }
      }
    end

    assert @entry.reload.excluded?
    children = @entry.child_entries.order(:amount)
    assert_equal(-30, children.first.amount.to_i)
    assert_equal 130, children.last.amount.to_i
  end

  test "only family members can access splits" do
    other_family_entry = create_transaction(
      amount: 100,
      name: "Other",
      account: accounts(:depository)
    )

    # This should work since both belong to same family
    get new_transaction_split_path(other_family_entry)
    assert_response :success
  end

  test "create with excluded parameter sets child as excluded" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: categories(:food_and_drink).id, excluded: "true" },
            { name: "Household", amount: "-30", category_id: "", excluded: "false" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    children = @entry.child_entries.order(:amount)
    # Household has amount 30 (smaller), Groceries has amount 70 (larger)
    # Household is NOT excluded, Groceries IS excluded
    refute children.first.excluded?
    assert children.last.excluded?
  end

  test "create with merchant and tags sets them on children" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: "", merchant_id: merchants(:amazon).id, tag_ids: [ tags(:one).id, tags(:two).id ] },
            { name: "Household", amount: "-30", category_id: "" }
          ]
        }
      }
    end

    children = @entry.child_entries.order(:amount)
    groceries = children.find { |c| c.name == "Groceries" }
    household = children.find { |c| c.name == "Household" }

    assert_equal merchants(:amazon).id, groceries.entryable.merchant_id
    assert_equal [ tags(:one), tags(:two) ].sort_by(&:id), groceries.entryable.tags.sort_by(&:id)
    assert_nil household.entryable.merchant_id
  end

  test "create ignores merchant and tags belonging to another family" do
    other_family = families(:empty)
    foreign_merchant = other_family.merchants.create!(name: "Foreign merchant", type: "FamilyMerchant")
    foreign_tag = other_family.tags.create!(name: "Foreign tag")

    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: "", merchant_id: foreign_merchant.id, tag_ids: [ foreign_tag.id ] },
            { name: "Household", amount: "-30", category_id: "" }
          ]
        }
      }
    end

    groceries = @entry.child_entries.order(:amount).find { |c| c.name == "Groceries" }
    assert_nil groceries.entryable.merchant_id
    assert_empty groceries.entryable.tags
  end

  # Edit action tests
  test "edit renders with existing children pre-filled" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    get edit_transaction_split_path(@entry)
    assert_response :success
  end

  test "edit keeps a saved split amount's decimals, capped at four" do
    @entry.split!([
      { name: "Part 1", amount: 60.125, category_id: nil },
      { name: "Part 2", amount: 39.875, category_id: nil }
    ])

    get edit_transaction_split_path(@entry)

    assert_select "input[name$='[amount]'][value='-60.125'][step='0.001']"
    assert_select "input[name$='[amount]'][value='-39.875']"
  end

  test "new gives every row at least the total's decimals" do
    jpy_entry = create_transaction(amount: 80.4, currency: "JPY", name: "Imported", account: accounts(:depository))

    get new_transaction_split_path(jpy_entry)

    # The first row and the template for added rows, so 40 + 40.4 can be typed.
    assert_select "input[name$='[amount]'][step='0.1']", count: 2
    assert_select "[data-split-transaction-total-value='-80.4']"
  end

  test "edit lists split rows in the order they were entered" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    queries = sql_queries { get edit_transaction_split_path(@entry) }
    assert_response :success
    # Without an ORDER BY PostgreSQL returns the rows in physical order.
    row_reads = queries.select { |sql| sql.include?('"entries"."parent_entry_id" =') && !sql.include?("SELECT 1 AS one") }
    assert row_reads.any?, "expected the split rows to be read"
    assert row_reads.all? { |sql| sql.include?('ORDER BY "entries"."created_at" ASC, "entries"."id" ASC') }, row_reads.join("\n")

    doc = Nokogiri::HTML::Document.parse(response.body)
    names = doc.css("[data-split-transaction-target='rowsContainer'] input[name$='[name]']").map { |input| input["value"] }
    assert_equal [ "Part 1", "Part 2" ], names
  end

  test "edit on a child redirects to parent edit" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    child = @entry.child_entries.first

    get edit_transaction_split_path(child)
    assert_response :success
  end

  test "edit on a non-split entry redirects with alert" do
    get edit_transaction_split_path(@entry)
    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.edit.not_split"), flash[:alert]
  end

  # Update action tests
  test "update modifies split entries" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Food", amount: "-50", category_id: categories(:food_and_drink).id },
          { name: "Transport", amount: "-30", category_id: "" },
          { name: "Other", amount: "-20", category_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.update.success"), flash[:notice]
    @entry.reload
    assert @entry.split_parent?
    assert_equal 3, @entry.child_entries.count
  end

  test "update names a part whose name was cleared after its category" do
    @user.family.update!(auto_generate_transaction_names: true)
    @entry.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "", amount: "-60", category_id: categories(:food_and_drink).id },
          { name: "Part 2", amount: "-40" }
        ]
      }
    }

    assert_equal [ "Food & Drink", "Part 2" ], @entry.reload.child_entries.in_split_order.pluck(:name)
  end

  test "update with mismatched amounts rejects" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-70", category_id: "" },
          { name: "Part 2", amount: "-20", category_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    assert flash[:alert].present?
    # Original splits should remain intact
    assert_equal 2, @entry.reload.child_entries.count
  end

  test "update with excluded parameter sets child as excluded" do
    @entry.split!([
      { name: "Groceries", amount: 70, category_id: nil },
      { name: "Household", amount: 30, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Groceries", amount: "-70", category_id: "", excluded: "true" },
          { name: "Household", amount: "-30", category_id: "", excluded: "false" }
        ]
      }
    }

    assert_redirected_to transactions_url
    children = @entry.child_entries.order(:amount)
    refute children.first.excluded?
    assert children.last.excluded?
  end

  test "update sets merchant and tags on children" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: merchants(:netflix).id, tag_ids: [ tags(:three).id ] },
          { name: "Part 2", amount: "-40", category_id: "" }
        ]
      }
    }

    part_one = @entry.reload.child_entries.order(:amount).find { |c| c.name == "Part 1" }
    assert_equal merchants(:netflix).id, part_one.entryable.merchant_id
    assert_equal [ tags(:three) ], part_one.entryable.tags
  end

  test "new prefills every row with the parent's merchant" do
    @entry.transaction.update!(merchant: merchants(:amazon))

    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    first_row = doc.at_css("[data-split-transaction-target='rowsContainer'] input[type='hidden'][name='split[splits][0][merchant_id]']")
    assert_equal merchants(:amazon).id, first_row["value"]
    assert_includes doc.at_css("[data-split-transaction-target='rowsContainer'] #split_splits_0_merchant_id").text, merchants(:amazon).name

    template = Nokogiri::HTML::DocumentFragment.parse(doc.at_css("template[data-split-transaction-target='rowTemplate']").inner_html)
    assert_equal merchants(:amazon).id, template.at_css("input[type='hidden'][name='split[splits][ROW_IDX_PLACEHOLDER][merchant_id]']")["value"]
  end

  test "new leaves the merchant empty when the parent has none" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    assert_equal "", doc.at_css("input[type='hidden'][name='split[splits][0][merchant_id]']")["value"]
  end

  test "edit prefills added rows with the parent's merchant" do
    @entry.transaction.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil, merchant_id: merchants(:netflix).id },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    get edit_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    rows = doc.css("[data-split-transaction-target='rowsContainer'] input[type='hidden'][name$='[merchant_id]']").map { |input| input["value"] }
    assert_equal [ merchants(:netflix).id, merchants(:amazon).id ], rows

    template = Nokogiri::HTML::DocumentFragment.parse(doc.at_css("template[data-split-transaction-target='rowTemplate']").inner_html)
    assert_equal merchants(:amazon).id, template.at_css("input[type='hidden'][name$='[merchant_id]']")["value"]
  end

  test "create passes a prefilled parent merchant on to the split as sent" do
    @entry.transaction.update!(merchant: merchants(:amazon))

    Entry.any_instance.expects(:split_once!).with do |splits, **|
      splits.map { |split| split[:merchant_id] } == [ merchants(:amazon).id, merchants(:netflix).id ]
    end.returns(true)

    post transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Groceries", amount: "-70", category_id: "", merchant_id: merchants(:amazon).id },
          { name: "Household", amount: "-30", category_id: "", merchant_id: merchants(:netflix).id }
        ]
      }
    }
  end

  test "update passes a prefilled parent merchant on to the split as sent" do
    @entry.transaction.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    Entry.any_instance.expects(:resplit!).with do |splits, **|
      splits.map { |split| split[:merchant_id] } == [ merchants(:amazon).id, merchants(:netflix).id ]
    end.returns(true)

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: merchants(:amazon).id },
          { name: "Part 2", amount: "-40", category_id: "", merchant_id: merchants(:netflix).id }
        ]
      }
    }
  end

  # Destroy from child tests
  test "destroy from child resolves to parent and unsplits" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    child = @entry.child_entries.first

    assert_difference "Entry.count", -2 do
      delete transaction_split_path(child)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.destroy.success"), flash[:notice]
    refute @entry.reload.excluded?
  end

  test "destroy refuses while a part is linked as a transfer" do
    part = @entry.split!([ { name: "Principal", amount: 60 }, { name: "Interest", amount: 40 } ]).first
    link_split_part_to_loan(part)

    assert_no_difference "Entry.count" do
      delete transaction_split_path(@entry)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.edit.part_transferred"), flash[:alert]
    assert @entry.reload.split_parent?
  end

  test "update refuses while a part is linked as a transfer" do
    part = @entry.split!([ { name: "Principal", amount: 60 }, { name: "Interest", amount: 40 } ]).first
    link_split_part_to_loan(part)

    patch transaction_split_path(@entry), params: {
      split: { splits: [ { name: "A", amount: "-50" }, { name: "B", amount: "-50" } ] }
    }

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.edit.part_transferred"), flash[:alert]
    assert_equal %w[Interest Principal], @entry.reload.child_entries.order(:name).pluck(:name)
  end

  test "update keeps a cleared merchant empty instead of taking the parent's" do
    @entry.entryable.update!(merchant: merchants(:netflix))
    @entry.split!([
      { name: "Part 1", amount: 60 },
      { name: "Part 2", amount: 40 }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: "" },
          { name: "Part 2", amount: "-40", category_id: "", merchant_id: merchants(:netflix).id }
        ]
      }
    }

    children = @entry.reload.child_entries.order(:amount)
    assert_equal({ "Part 1" => nil, "Part 2" => merchants(:netflix).id }, children.to_h { |c| [ c.name, c.entryable.merchant_id ] })
  end

  test "rules keep the names and categories the person gave split parts" do
    post transaction_split_path(@entry), params: { split: { splits: [
      { name: "Groceries", amount: "-70", category_id: categories(:food_and_drink).id },
      { name: "Household", amount: "-30", category_id: "" }
    ] } }
    assert_split_parts_survive_rules(@entry, expected_categories: [ categories(:food_and_drink), categories(:income) ],
                                             expected_names: %w[Groceries Household])

    patch transaction_split_path(@entry), params: { split: { splits: [
      { name: "Food", amount: "-60", category_id: categories(:food_and_drink).id },
      { name: "Other", amount: "-40", category_id: "" }
    ] } }
    assert_split_parts_survive_rules(@entry, expected_categories: [ categories(:food_and_drink), categories(:income) ],
                                             expected_names: %w[Food Other])
  end

  test "a split part ends up like the same input in the new transaction form" do
    create_split_contract_rule(@user.family)
    merchant = @user.family.merchants.create!(name: "Contract merchant", type: "FamilyMerchant")
    row = { category_id: categories(:food_and_drink).id, merchant_id: merchant.id, tag_ids: [ tags(:one).id ] }

    post transactions_url, params: { entry: {
      account_id: @entry.account_id, name: "Contract row", date: @entry.date, currency: @entry.currency,
      amount: 70, nature: "outflow", entryable_type: "Transaction", entryable_attributes: row
    } }
    created = @entry.account.entries.find_by!(name: "Contract row", parent_entry_id: nil)

    post transaction_split_path(@entry), params: { split: { splits: [
      { name: "Contract row", amount: "-70", **row },
      { name: "Rest", amount: "-30" }
    ] } }
    part = @entry.child_entries.find_by!(name: "Contract row")

    assert_finished_like created, part
    assert part.user_modified?
  end

  test "editing a split finishes the new parts like new transactions" do
    create_split_contract_rule(@user.family)
    @entry.split!([ { name: "Old A", amount: 50 }, { name: "Old B", amount: 50 } ])

    patch transaction_split_path(@entry), params: { split: { splits: [
      { name: "Contract row", amount: "-70", category_id: categories(:food_and_drink).id, tag_ids: [ tags(:one).id ] },
      { name: "Rest", amount: "-30" }
    ] } }
    part = @entry.child_entries.find_by!(name: "Contract row")

    assert_equal({ entry: %w[amount name], transaction: %w[category_id tag_ids] }, split_contract_locks(part))
    assert part.user_modified?
    assert_immediate_rules_enqueued_for part
  end

  private
    def sql_queries(&block)
      queries = []
      ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] }, "sql.active_record", &block)
      queries
    end
end
