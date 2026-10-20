require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  test "timezone options have unique values so the saved zone stays selected" do
    values = timezone_options.map(&:last)

    assert_equal values.uniq, values
  end

  test "timezone options list each zone once, without old aliases" do
    canonicals = timezone_options.map { |_, value| ActiveSupport::TimeZone[value].tzinfo.canonical_identifier }

    assert_equal canonicals.uniq, canonicals
  end

  test "timezone options list each IANA zone with its identifier" do
    moscow = timezone_options.select { |_, value| value == "Europe/Moscow" }

    assert_equal [ [ "(+03:00) Europe/Moscow", "Europe/Moscow" ] ], moscow
    assert_includes timezone_options.map(&:last), "America/Argentina/Cordoba"
  end

  test "timezone options cover every zone offered by Rails" do
    canonical = ->(identifier) { ActiveSupport::TimeZone[identifier].tzinfo.canonical_identifier }
    listed = timezone_options.map { |_, value| canonical.call(value) }
    rails_zones = ActiveSupport::TimeZone.all.map { |tz| canonical.call(tz.tzinfo.identifier) }

    assert_empty rails_zones - listed
  end

  test "timezone options are sorted by offset and use readable labels" do
    offsets = timezone_options.map { |_, value| ActiveSupport::TimeZone[value].utc_offset }

    assert_equal offsets.sort, offsets
    assert_includes timezone_options, [ "(-05:00) America/New York", "America/New_York" ]
  end

  test "timezone options use a saved alias in place of its zone" do
    base = timezone_options
    # Hosts without tzdata's legacy links cannot resolve "Europe/Kiev", so
    # resolve it to the Kyiv zone it links to.
    ActiveSupport::TimeZone.stubs(:[]).with("Europe/Kiev")
      .returns(stub(tzinfo: TZInfo::Timezone.get("Europe/Kyiv"), utc_offset: 2.hours.to_i))

    options = timezone_options("Europe/Kiev")

    assert_includes options, [ "(+02:00) Europe/Kiev", "Europe/Kiev" ]
    assert_not_includes options.map(&:last), "Europe/Kyiv"
    assert_equal base.size, options.size
  end

  test "timezone options ignore an unknown saved zone" do
    assert_equal timezone_options, timezone_options("Not/AZone")
  end
end
