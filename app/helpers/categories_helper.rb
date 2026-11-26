module CategoriesHelper
  # Data attributes for one row of a category picker, so that every picker
  # finds a category by the same rule (utils/search_match): the shown label,
  # every name it may be typed as (stored name first, see
  # Category#search_names) and its place in the tree. Merge them into the
  # row's data; test/integration/category_pickers_search_test.rb checks that
  # every picker does.
  def category_search_data(category, label: category.display_name)
    {
      filter_name: label,
      filter_terms: category.search_names.to_json,
      filter_id: category.id,
      filter_parent_id: category.parent_id
    }
  end

  def transfer_category
    Category.new \
      name: I18n.t("categories.virtual.transfer"),
      color: Category::TRANSFER_COLOR,
      lucide_icon: "arrow-right-left"
  end

  def payment_category
    Category.new \
      name: I18n.t("categories.virtual.payment"),
      color: Category::PAYMENT_COLOR,
      lucide_icon: "arrow-right"
  end

  def trade_category
    Category.new \
      name: I18n.t("categories.virtual.trade"),
      color: Category::TRADE_COLOR
  end

  # The outflow's category an inflow leg of a categorizable transfer shows
  # read-only (Transaction#category_set_on_transfer_outflow?), or nil when it
  # shows none. Like the counterpart name in transactions/_transaction, it is
  # hidden when the viewer cannot access the outflow's account.
  def transfer_outflow_category(transaction, accessible_account_ids: @accessible_account_ids)
    return unless transaction.category_set_on_transfer_outflow?

    from_account_id = transaction.transfer.outflow_transaction.entry.account_id
    visible = if accessible_account_ids
      accessible_account_ids.include?(from_account_id)
    else
      Current.user.present? && Current.user.accessible_accounts.exists?(id: from_account_id)
    end
    return unless visible

    transaction.transfer.outflow_transaction.category || Category.uncategorized
  end

  # The badge a transaction shows when its category is not editable.
  def read_only_category(transaction)
    transfer_outflow_category(transaction) || (transaction.payment? ? payment_category : transfer_category)
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically_by_hierarchy)
  end
end
