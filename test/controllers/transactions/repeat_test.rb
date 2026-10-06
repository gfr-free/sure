require "test_helper"

# "Repeat" on the new-transaction form: the entry plus a series that starts
# with it (RecurringTransaction::FromNewEntry).
class Transactions::RepeatTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @account = accounts(:depository)
    ensure_tailwind_build
  end

  test "the form offers repeat with frequency and auto-post behind the preview gate" do
    get new_transaction_url

    assert_response :success
    assert_select "input[name='repeat[enabled]'][type=checkbox]"
    assert_select "select[name='repeat[frequency_preset]']"
    assert_select "input[name='repeat[auto_post]'][type=checkbox][checked]"
    # Twice a month needs a second day the form does not ask for.
    assert_select "select[name='repeat[frequency_preset]'] option[value='semimonthly']", count: 0
  end

  test "a malformed repeat param is ignored rather than failing" do
    get new_transaction_url(repeat: "1")
    assert_response :success

    assert_difference "Entry.count", 1 do
      post transactions_url, params: entry_params(name: "Coffee", amount: 4).merge(repeat: "1")
    end
  end

  test "the form hides repeat without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get new_transaction_url

    assert_response :success
    assert_select "input[name='repeat[enabled]']", count: 0
  end

  test "the form hides repeat for a linked account" do
    get new_transaction_url(account_id: accounts(:connected).id)

    assert_response :success
    assert_select "input[name='repeat[enabled]']", count: 0
  end

  test "saving with repeat creates the entry, an auto-posting series and pays its first date" do
    travel_to Time.zone.local(2026, 10, 6, 12) do
      assert_difference [ "Entry.count", "RecurringTransaction.count" ], 1 do
        post transactions_url, params: entry_params(name: "Rent", amount: 900).merge(
          repeat: { enabled: "1", frequency_preset: "monthly", auto_post: "1" }
        )
      end
    end

    entry = @account.entries.find_by!(name: "Rent")
    series = @family.recurring_transactions.find_by!(name: "Rent")

    assert_equal "Transaction created and set to repeat", flash[:notice]
    assert_equal @account, series.account
    assert_equal 900, series.amount
    assert series.typed_bill?
    assert series.auto_post?
    assert_equal categories(:food_and_drink).id, series.category_id

    first = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 10, 6))
    assert_equal [ entry.id ], first.allocations.pluck(:entry_id)
    assert first.paid?
    assert series.recurring_occurrences.exists?(due_on: Date.new(2026, 11, 6))

    # The first date is paid, so the nightly run posts nothing for it.
    assert_no_difference "Entry.count" do
      RecurringTransaction::Poster.new(@family, today: Date.new(2026, 10, 6)).post_due!
    end
  end

  test "an income repeats as income with the chosen interval" do
    post transactions_url, params: entry_params(name: "Salary", amount: 3000, nature: "inflow").merge(
      repeat: { enabled: "1", frequency_preset: "interval", frequency_interval: "2", frequency_interval_unit: "weekly", auto_post: "0" }
    )

    series = @family.recurring_transactions.find_by!(name: "Salary")
    assert series.typed_income?
    assert_equal(-3000, series.amount)
    assert_not series.auto_post?
    assert_equal 1, series.recurring_occurrences.joins(:allocations).count
  end

  test "a backdated entry pays the first date and keeps the dates since then" do
    travel_to Time.zone.local(2026, 10, 6, 12) do
      post transactions_url, params: entry_params(name: "Gym", amount: 30, date: Date.new(2026, 7, 15)).merge(
        repeat: { enabled: "1", frequency_preset: "monthly", auto_post: "1" }
      )
    end

    series = @family.recurring_transactions.find_by!(name: "Gym")
    first = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 7, 15))
    assert first.paid?
    assert_equal [ Date.new(2026, 8, 15), Date.new(2026, 9, 15), Date.new(2026, 10, 15) ],
                 series.recurring_occurrences.where(status: "scheduled").order(:due_on).limit(3).pluck(:due_on)
  end

  test "without repeat nothing but the entry is created" do
    assert_no_difference "RecurringTransaction.count" do
      post transactions_url, params: entry_params(name: "Coffee", amount: 4).merge(repeat: { enabled: "0" })
    end

    assert_equal "Transaction created", flash[:notice]
  end

  test "repeat is ignored without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    assert_difference "Entry.count", 1 do
      assert_no_difference "RecurringTransaction.count" do
        post transactions_url, params: entry_params(name: "Rent", amount: 900).merge(
          repeat: { enabled: "1", frequency_preset: "monthly", auto_post: "1" }
        )
      end
    end
  end

  test "repeat on a linked account saves nothing and says why" do
    assert_no_difference [ "Entry.count", "RecurringTransaction.count" ] do
      post transactions_url, params: entry_params(name: "Rent", amount: 900, account: accounts(:connected)).merge(
        repeat: { enabled: "1", frequency_preset: "monthly", auto_post: "1" }
      )
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Repeat is only available for manual accounts"
  end

  test "a series that already exists rolls the entry back" do
    params = entry_params(name: "Rent", amount: 900).merge(repeat: { enabled: "1", frequency_preset: "monthly", auto_post: "0" })
    post transactions_url, params: params

    assert_no_difference [ "Entry.count", "RecurringTransaction.count" ] do
      post transactions_url, params: entry_params(name: "Rent", amount: 900).merge(params.slice(:repeat))
    end

    assert_response :unprocessable_entity
  end

  test "a foreign-currency entry cannot repeat" do
    assert_no_difference [ "Entry.count", "RecurringTransaction.count" ] do
      post transactions_url, params: entry_params(name: "Hotel", amount: 100, currency: "EUR").merge(
        repeat: { enabled: "1", frequency_preset: "monthly", auto_post: "1" }
      )
    end

    assert_response :unprocessable_entity
  end

  private
    def entry_params(name:, amount:, nature: "outflow", date: Date.current, account: @account, currency: "USD")
      {
        entry: {
          account_id: account.id,
          name: name,
          date: date,
          currency: currency,
          amount: amount,
          nature: nature,
          entryable_type: "Transaction",
          entryable_attributes: { category_id: categories(:food_and_drink).id }
        }
      }
    end
end
