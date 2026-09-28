require "test_helper"

class ContractNoticeRemindersJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @owner = users(:family_admin)
    @owner.update!(preferences: (@owner.preferences || {}).merge("preview_features_enabled" => true))
    @insurance = contracts(:liability_insurance)
    # Only the insurance fixture has a deadline in these windows.
    contracts(:phone_plan).update!(email_reminders: false)
  end

  teardown do
    travel_back
  end

  test "emails the owner once per stage ahead of the deadline" do
    travel_to Date.new(2026, 9, 1)

    assert_enqueued_emails 1 do
      ContractNoticeRemindersJob.perform_now
    end
    assert_equal({ "2026-09-30" => [ 30 ] }, @insurance.reload.notice_reminders_sent)

    assert_no_enqueued_emails do
      ContractNoticeRemindersJob.perform_now
    end

    travel_to Date.new(2026, 9, 25)
    assert_enqueued_emails 1 do
      ContractNoticeRemindersJob.perform_now
    end
    assert_equal [ 30, 7 ], @insurance.reload.notice_reminders_sent["2026-09-30"]
  end

  test "a missed run catches up with the most urgent stage only" do
    travel_to Date.new(2026, 9, 29)

    assert_enqueued_emails 1 do
      ContractNoticeRemindersJob.perform_now
    end
    assert_equal [ 30, 7, 1 ], @insurance.reload.notice_reminders_sent["2026-09-30"]
  end

  test "respects the per-contract switch and the owner's preview access" do
    travel_to Date.new(2026, 9, 1)
    @insurance.update!(email_reminders: false)

    assert_no_enqueued_emails { ContractNoticeRemindersJob.perform_now }

    @insurance.update!(email_reminders: true)
    @owner.update!(preferences: @owner.preferences.merge("preview_features_enabled" => false))
    assert_no_enqueued_emails { ContractNoticeRemindersJob.perform_now }
  end

  test "the email names the deadline and leaves the contract number out" do
    travel_to Date.new(2026, 9, 1)

    mail = ContractMailer.notice_reminder(contract: @insurance, deadline: Date.new(2026, 9, 30), term_ends_on: Date.new(2026, 12, 31))

    assert_equal [ @owner.email ], mail.to
    assert_match @insurance.name, mail.subject
    assert_match I18n.l(Date.new(2026, 9, 30), format: :long), mail.text_part.body.to_s
    assert_no_match "LV-2024-004711", mail.html_part.body.to_s
    assert_no_match "LV-2024-004711", mail.text_part.body.to_s
  end
end
