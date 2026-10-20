require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  test "timezone options have unique values so the saved zone stays selected" do
    values = timezone_options.map(&:last)

    assert_equal values.uniq, values
  end

  test "timezone options list each IANA zone once with its identifier" do
    moscow = timezone_options.select { |_, value| value == "Europe/Moscow" }

    assert_equal [ [ "(+03:00) Europe/Moscow", "Europe/Moscow" ] ], moscow
    assert_includes timezone_options.map(&:last), "America/Argentina/Cordoba"
  end

  test "timezone options keep every zone offered by Rails" do
    rails_identifiers = ActiveSupport::TimeZone.all.map { |tz| tz.tzinfo.identifier }

    assert_empty rails_identifiers - timezone_options.map(&:last)
  end

  test "timezone options are sorted by offset and use readable labels" do
    offsets = timezone_options.map { |_, value| ActiveSupport::TimeZone[value].utc_offset }

    assert_equal offsets.sort, offsets
    assert_includes timezone_options, [ "(-05:00) America/New York", "America/New_York" ]
  end

  test "timezone options append a saved zone that is not in the list" do
    options = timezone_options("Europe/Belfast")

    assert_includes options.map(&:last), "Europe/Belfast"
    assert_not_includes timezone_options.map(&:last), "Europe/Belfast"
  end

  test "timezone options ignore an unknown saved zone" do
    assert_equal timezone_options, timezone_options("Not/AZone")
  end
end
