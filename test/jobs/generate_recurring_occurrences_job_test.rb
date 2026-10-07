require "test_helper"

class GenerateRecurringOccurrencesJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "posts due entries after generating occurrences" do
    RecurringTransaction::Poster.any_instance.expects(:post_due!).once

    GenerateRecurringOccurrencesJob.perform_now(@family.id)
  end

  test "skips a family with recurring transactions disabled" do
    @family.update!(recurring_transactions_disabled: true)
    RecurringTransaction::Poster.any_instance.expects(:post_due!).never

    GenerateRecurringOccurrencesJob.perform_now(@family.id)
  end
end
