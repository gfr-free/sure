require "application_system_test_case"

# The rate-change rows share their input names ("rate_changes[][rate]"), and
# the server pairs each rate with its date by the order of the submitted
# entries. The rate is a decimal field, which rewrites its own entry to the
# dot form on submit; that rewrite must not collapse the other rows' rates.
class LoanRateChangesTest < ApplicationSystemTestCase
  RATE = "account[accountable_attributes][rate_changes][][rate]".freeze
  DATE = "account[accountable_attributes][rate_changes][][effective_date]".freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false, locale: "de")
    @account = accounts(:loan)
    @account.loan.update!(rate_type: "variable", start_date: Date.new(2026, 1, 1),
                          variable_rate_schedule: { "2026-04-01" => "7.25", "2026-07-01" => "6.5" })
  end

  test "every rate-change row submits its own rate in dot form, after its date" do
    visit edit_loan_url(@account)
    assert_selector "input[name='#{RATE}'][value='7,25']", visible: :all

    # new FormData(form) fires the same "formdata" event a submit does.
    expected = [ [ DATE, "2026-04-01" ], [ RATE, "7.250" ], [ DATE, "2026-07-01" ], [ RATE, "6.500" ] ]
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, submitted_rate_rows.inspect unless submitted_rate_rows == expected
    end
  end

  private
    def submitted_rate_rows
      page.evaluate_script(<<~JS)
        (() => {
          const form = document.querySelector("input[name='#{RATE}']").form
          return [...new FormData(form).entries()].filter(([key]) => key === "#{RATE}" || key === "#{DATE}")
        })()
      JS
    end
end
