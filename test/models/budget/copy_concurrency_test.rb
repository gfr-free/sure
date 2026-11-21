require "test_helper"
require "concurrent"

# copy_from! locks the target budget lines and then recomputes the rollover
# chain, while a recompute holds the chain lock and then writes those lines.
# Real connections and commits, so the lock order between them is exercised.
class Budget::CopyConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Budget copy race", currency: "USD")
    @category = @family.categories.create!(name: "Groceries", color: "#0d9488", lucide_icon: "tag")

    @source = budget_for(2.months.ago)
    @target = budget_for(1.month.ago)
    BudgetCategory.create!(budget: @source, category: @category, budgeted_spending: 500, currency: "USD", rollover_enabled: true)
    @target_line = BudgetCategory.create!(budget: @target, category: @category, budgeted_spending: 0, currency: "USD")
  end

  teardown do
    BudgetCategory.where(budget_id: [ @source&.id, @target&.id ]).delete_all
    Budget.where(family_id: @family.id).delete_all if @family
    Category.where(family_id: @family.id).delete_all if @family
    Rule.where(family_id: @family.id).destroy_all if @family
    Family.where(id: @family.id).delete_all if @family
  end

  test "copy_from! waits for a running recompute instead of deadlocking with it" do
    chain_locked = Concurrent::CountDownLatch.new(1)

    recompute = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        BudgetCategory.transaction do
          Budget::RolloverCalculator.new(family: @family, user: nil).lock_chain!
          chain_locked.count_down
          wait_for_blocked_chain_lock
          # A recompute writes the target line while it holds the chain lock.
          BudgetCategory.where(id: @target_line.id).update_all(updated_at: Time.current)
        end
        :ok
      rescue ActiveRecord::Deadlocked => e
        e
      end
    end

    copy = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        chain_locked.wait(5)
        Budget.find(@target.id).copy_from!(Budget.find(@source.id))
        :ok
      rescue ActiveRecord::Deadlocked => e
        e
      end
    end

    assert_equal [ :ok, :ok ], [ recompute.value, copy.value ]
    assert @target_line.reload.rollover_enabled?
  end

  private
    def budget_for(date)
      Budget.create!(
        family: @family, start_date: date.beginning_of_month, end_date: date.end_of_month,
        budgeted_spending: 500, expected_income: 1000, currency: "USD"
      )
    end

    # Waits until the copy blocks on the chain lock this thread holds.
    def wait_for_blocked_chain_lock
      deadline = 5.seconds.from_now
      until blocked_chain_lock? || Time.current > deadline
        sleep 0.05
      end
    end

    def blocked_chain_lock?
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).present?
        SELECT 1 FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted
          AND classid = #{Budget::RolloverCalculator::LOCK_NAMESPACE}
          AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
      SQL
    end
end
