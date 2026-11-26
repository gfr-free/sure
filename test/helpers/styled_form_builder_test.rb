require "test_helper"

class StyledFormBuilderTest < ActionView::TestCase
  setup do
    @builder = StyledFormBuilder.new(:account_statement, nil, self, {})
  end

  test "a labelled file field sits in a form field with its label" do
    field = Nokogiri::HTML.fragment(@builder.file_field(:files, label: "Statement files")).at(".form-field")

    assert field, "expected the file input wrapped in a .form-field"
    assert_equal "account_statement_files", field.at("label.form-field__label")["for"]
    assert_includes field.at("input[type=file]")["class"].split, "file:bg-container-inset"
  end

  # text-destructive inverts in dark mode; a raw palette class does not.
  test "a required field marks its label with the destructive token" do
    field = Nokogiri::HTML.fragment(@builder.text_field(:name, label: "Name", required: true))
    marker = field.at("label.form-field__label span")

    assert marker, "expected a required marker in the label"
    assert_equal "*", marker.text
    assert_includes marker["class"].split, "text-destructive"
  end

  # The dropzones pass `hidden` and draw their own target: no wrapper, and
  # their classes merged in rather than replaced.
  test "an unlabelled file field comes back bare and keeps the caller's classes" do
    fragment = Nokogiri::HTML.fragment(@builder.file_field(:files, class: "hidden"))

    assert_nil fragment.at(".form-field")
    assert_includes fragment.at("input[type=file]")["class"].split, "hidden"
  end

  test "an entry date field starts the day after the earliest date the model accepts" do
    entry = Entry.new(date: Date.new(2026, 3, 4))
    builder = StyledFormBuilder.new(:entry, entry, self, {})
    input = Nokogiri::HTML.fragment(builder.entry_date_field(:date, label: "Date")).at("input[type=date]")

    assert_equal (Entry.min_supported_date + 1.day).iso8601, input["min"]
    assert_equal "2026-03-04", input["value"]
    assert_nil input["max"]
    assert_not Entry.new(date: Entry.min_supported_date).tap(&:validate).errors[:date].empty?
    assert_empty Entry.new(date: Entry.min_supported_date + 1.day).tap(&:validate).errors[:date]
  end

  test "an entry date field defaults to today and can be capped at today" do
    travel_to Time.zone.local(2026, 5, 6, 12) do
      builder = StyledFormBuilder.new(:entry, Entry.new, self, {})
      input = Nokogiri::HTML.fragment(builder.entry_date_field(:date, past_only: true)).at("input[type=date]")

      assert_equal "2026-05-06", input["value"]
      assert_equal "2026-05-06", input["max"]
    end
  end

  # The drawer's date shares a form with the amount; a minimum above the
  # saved date would block saving the amount.
  test "an entry date older than the limit stays selectable" do
    old_date = Entry.min_supported_date - 3.days
    entry = entries(:transaction)
    entry.update_column(:date, old_date)
    entry.date = Date.current
    builder = StyledFormBuilder.new(:entry, entry, self, {})
    input = Nokogiri::HTML.fragment(builder.entry_date_field(:date)).at("input[type=date]")

    assert_equal old_date.iso8601, input["min"]
  end

  test "a new entry gets the usual lower bound even with an old date typed in" do
    builder = StyledFormBuilder.new(:entry, Entry.new(date: Entry.min_supported_date - 3.days), self, {})
    input = Nokogiri::HTML.fragment(builder.entry_date_field(:date)).at("input[type=date]")

    assert_equal (Entry.min_supported_date + 1.day).iso8601, input["min"]
  end

  test "a past-only entry date keeps a saved future date selectable" do
    travel_to Time.zone.local(2026, 5, 6, 12) do
      entry = entries(:valuation)
      entry.update_column(:date, Date.new(2026, 6, 1))
      builder = StyledFormBuilder.new(:entry, entry, self, {})
      input = Nokogiri::HTML.fragment(builder.entry_date_field(:date, past_only: true)).at("input[type=date]")

      assert_equal "2026-06-01", input["max"]
    end
  end

  test "a virtual date attribute widens the bounds by the date it shows" do
    travel_to Time.zone.local(2026, 5, 6, 12) do
      vehicle = accounts(:vehicle).accountable
      anchor = Entry.min_supported_date - 2.days
      builder = StyledFormBuilder.new(:vehicle, vehicle, self, {})
      input = Nokogiri::HTML.fragment(builder.entry_date_field(:purchase_date, value: anchor, past_only: true)).at("input[type=date]")

      assert_equal anchor.iso8601, input["min"]
      assert_equal "2026-05-06", input["max"]
    end
  end

  test "a sync start date field stops at today unless a later date is saved" do
    travel_to Time.zone.local(2026, 5, 6, 12) do
      fresh = StyledFormBuilder.new(:connection, Struct.new(:sync_start_date).new(nil), self, {})
      assert_equal "2026-05-06", Nokogiri::HTML.fragment(fresh.sync_start_date_field).at("input")["max"]

      saved = Struct.new(:sync_start_date, :persisted?).new(Date.new(2026, 7, 1), true)
      builder = StyledFormBuilder.new(:connection, saved, self, {})
      assert_equal "2026-07-01", Nokogiri::HTML.fragment(builder.sync_start_date_field).at("input")["max"]
    end
  end

  test "an entry date field keeps an explicit min, also as a string key" do
    builder = StyledFormBuilder.new(:entry, Entry.new, self, {})
    input = Nokogiri::HTML.fragment(builder.entry_date_field(:date, "min" => "2020-01-01")).at("input[type=date]")

    assert_equal "2020-01-01", input["min"]
  end

  test "an entry date field stays blank when blank means unchanged" do
    builder = StyledFormBuilder.new(:bulk_update, nil, self, {})
    input = Nokogiri::HTML.fragment(builder.entry_date_field(:date, value: nil)).at("input[type=date]")

    assert_nil input["value"]
  end
end
