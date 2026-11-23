require "test_helper"

class Transaction::ReviewQueueTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Every transaction here carries this word in its name, and every queue
  # searches for it, so fixture transactions never move the counts.
  MARKER = "Reviewqueuemarker".freeze

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @category = categories(:food_and_drink)
    @merchant = merchants(:netflix)
  end

  test "counts each review kind" do
    review_transaction(category: nil, merchant: @merchant)                      # uncategorized
    review_transaction(category: @category, merchant: nil)                      # no merchant
    review_transaction(category: @category, merchant: @merchant,
                       date: 10.days.ago.to_date, extra: pending_extra)          # long pending
    review_transaction(category: @category, merchant: @merchant,
                       extra: pending_extra.merge("potential_posted_match" => { "entry_id" => SecureRandom.uuid }))
    review_transaction(category: @category, merchant: @merchant)                # nothing to do

    counts = queue(@admin).counts

    assert_equal 1, counts["uncategorized"]
    assert_equal 1, counts["no_merchant"]
    assert_equal 1, counts["long_pending"]
    assert_equal 1, counts["possible_duplicate"]
    assert_equal 0, counts["transfer_suggestion"]
  end

  test "a recent pending transaction is not pending for long" do
    review_transaction(category: @category, merchant: @merchant, date: 2.days.ago.to_date, extra: pending_extra)

    assert_equal 0, queue(@admin).counts["long_pending"]
  end

  test "a dismissed duplicate hint is not counted" do
    review_transaction(category: @category, merchant: @merchant,
                       extra: { "potential_posted_match" => { "entry_id" => SecureRandom.uuid, "dismissed" => true } })

    assert_equal 0, queue(@admin).counts["possible_duplicate"]
  end

  test "an empty or cleared duplicate hint is not counted, like has_potential_duplicate?" do
    review_transaction(category: @category, merchant: @merchant, extra: { "potential_posted_match" => {} })
    review_transaction(category: @category, merchant: @merchant, extra: { "potential_posted_match" => nil })
    review_transaction(category: @category, merchant: @merchant,
                       extra: { "potential_posted_match" => { "entry_id" => SecureRandom.uuid, "dismissed" => "true" } })

    # The string "true" is not a dismissal for the Ruby predicate either.
    assert_equal 1, queue(@admin).counts["possible_duplicate"]
  end

  test "transfer kinds without a merchant or category are not review work" do
    review_transaction(category: nil, merchant: nil, kind: "funds_movement")
    review_transaction(category: nil, merchant: nil, kind: "loan_payment")

    counts = queue(@admin).counts

    # loan_payment stays categorizable, like on the Transactions "Uncategorized" filter.
    assert_equal 1, counts["uncategorized"]
    assert_equal 0, counts["no_merchant"]
  end

  test "excluded transactions are not review work" do
    review_transaction(category: nil, merchant: nil, excluded: true)

    assert queue(@admin).counts.values.all?(&:zero?)
  end

  test "a pending transfer counts once, on its outflow leg" do
    outflow = review_transaction(category: @category, merchant: @merchant, amount: 50)
    inflow = review_transaction(category: @category, merchant: @merchant, amount: -50, account: accounts(:credit_card))
    Transfer.create!(outflow_transaction: outflow.transaction, inflow_transaction: inflow.transaction, status: "pending")

    review = queue(@admin)

    assert_equal 1, review.counts["transfer_suggestion"]
    assert_equal [ outflow.transaction.id ], review.transactions_for("transfer_suggestion").pluck(:id)
  end

  test "a transfer suggestion is hidden when the viewer cannot see the other leg" do
    other_account = @family.accounts.create!(name: "Private savings", balance: 0, currency: "USD",
                                             accountable: Depository.new, owner: @admin)
    outflow = review_transaction(category: @category, merchant: @merchant, amount: 50)
    inflow = review_transaction(category: @category, merchant: @merchant, amount: -50, account: other_account)
    Transfer.create!(outflow_transaction: outflow.transaction, inflow_transaction: inflow.transaction, status: "pending")

    assert_equal 1, queue(@admin).counts["transfer_suggestion"]
    assert_equal 0, queue(@member).counts["transfer_suggestion"]
  end

  test "filters narrow every count" do
    review_transaction(category: nil, merchant: nil)
    review_transaction(category: nil, merchant: nil, account: accounts(:credit_card))

    narrowed = queue(@admin, accounts: [ accounts(:credit_card).name ]).counts

    assert_equal 2, queue(@admin).counts["uncategorized"]
    assert_equal 1, narrowed["uncategorized"]
    assert_equal 1, narrowed["no_merchant"]
  end

  test "only counts accounts the viewer can access" do
    private_account = @family.accounts.create!(name: "Admin only", balance: 0, currency: "USD",
                                               accountable: Depository.new, owner: @admin)
    review_transaction(category: nil, merchant: nil, account: private_account)

    assert_equal 1, queue(@admin).counts["uncategorized"]
    assert_equal 0, queue(@member).counts["uncategorized"]
    assert_empty queue(@member).transactions_for("uncategorized")
  end

  test "never counts another family's transactions" do
    other_family = families(:empty)
    other_user = users(:empty)
    other_account = other_family.accounts.create!(name: "Elsewhere", balance: 0, currency: "USD",
                                                  accountable: Depository.new, owner: other_user)
    review_transaction(category: nil, merchant: nil, account: other_account)

    assert_equal 0, queue(@admin).counts["uncategorized"]
    assert_equal 1, Transaction::ReviewQueue.new(other_family, user: other_user, filters: { "search" => MARKER }).counts["uncategorized"]
  end

  test "list for a kind matches its count" do
    3.times { review_transaction(category: nil, merchant: @merchant) }
    review = queue(@admin)

    assert_equal review.counts["uncategorized"], review.transactions_for("uncategorized").count
  end

  test "rejects unknown kinds" do
    assert_raises(ArgumentError) { queue(@admin).transactions_for("everything") }
  end

  private
    def queue(user, **filters)
      Transaction::ReviewQueue.new(@family, user: user, filters: { "search" => MARKER }.merge(filters.stringify_keys))
    end

    def review_transaction(category:, merchant:, extra: nil, **attrs)
      entry = create_transaction(name: "#{MARKER} #{SecureRandom.hex(3)}", category: category, merchant: merchant, **attrs)
      entry.transaction.update_column(:extra, extra) if extra
      entry
    end

    def pending_extra
      { "simplefin" => { "pending" => true } }
    end
end
