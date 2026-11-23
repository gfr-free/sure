require "test_helper"

class Receipt::ExtractionTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  Stage = Receipt::Extraction::Stage
  Reading = Receipt::Extraction::Stage::Reading

  setup do
    @family = families(:dylan_family)
    @receipt = Receipt.create_from_upload!(family: @family, user: users(:family_admin), file: uploaded_receipt(receipt_pdf([ "Total 1.00" ])))
  end

  test "finds the stages in their namespace, ordered by position" do
    stages = Receipt::Extraction.stages

    assert_includes stages, Receipt::Extraction::Stages::PdfText
    assert_equal stages.sort_by(&:position), stages
  end

  test "a later stage fills only the fields earlier ones left blank" do
    first = stage(10, "first", fields: { "amount" => field(BigDecimal("5")), "currency" => field("EUR") }, text: "first text")
    second = stage(20, "second", fields: { "amount" => field(BigDecimal("9")), "merchant_name" => field("Bakery"), "date" => field(Date.new(2026, 11, 20)) },
                                 text: "second text")

    result = run_with(first, second)

    assert_equal BigDecimal("5"), result.fields["amount"][:value]
    assert_equal "first", result.fields["amount"][:source]
    assert_equal "Bakery", result.fields["merchant_name"][:value]
    assert_equal "second", result.fields["merchant_name"][:source]
    assert_equal "first text\nsecond text", result.raw_text
  end

  test "stops once every field is known" do
    complete = stage(10, "complete", fields: Receipt::FIELDS.index_with { field("x") })
    later = stage(20, "later", fields: {})
    later.any_instance.expects(:read).never

    run_with(complete, later)
  end

  test "a stage that supplies the amount with its currency replaces a guessed currency" do
    first = stage(10, "first", fields: { "currency" => field("USD") })
    second = stage(20, "second", fields: { "amount" => field(BigDecimal("3")), "currency" => field("EUR") })

    result = run_with(first, second)

    assert_equal "EUR", result.fields["currency"][:value]
  end

  test "a settled field is not filled by a later stage" do
    first = stage(10, "first", fields: { "merchant_name" => field("Shop") }, settles: %w[amount])
    second = stage(20, "second", fields: { "amount" => field(BigDecimal("7")) })

    result = run_with(first, second)

    assert_nil result.fields["amount"]
  end

  test "a stage may replace a value it considers less certain" do
    first = stage(10, "first", fields: { "amount" => field(BigDecimal("1"), confidence: 0.3) })
    second = stage(20, "second", fields: { "amount" => field(BigDecimal("2"), confidence: 0.8) })
    second.define_method(:replaces?) { |_field, earlier| earlier[:confidence] < 0.5 }

    result = run_with(first, second)

    assert_equal BigDecimal("2"), result.fields["amount"][:value]
    assert_equal "second", result.fields["amount"][:source]
  end

  test "a failure after a stage read something keeps the fields and the error as a notice" do
    first = stage(10, "first", fields: { "amount" => field(BigDecimal("4")) })
    failing = stage(20, "failing", fields: {})
    failing.define_method(:read) { raise Receipt::Extraction::Error, "unreadable_pdf" }

    result = run_with(first, failing)

    assert_equal BigDecimal("4"), result.fields["amount"][:value]
    assert_equal "unreadable_pdf", result.notice
  end

  test "a failure before anything was read fails the run" do
    failing = stage(10, "failing", fields: {})
    failing.define_method(:read) { raise Receipt::Extraction::Error, "unreadable_pdf" }

    error = assert_raises(Receipt::Extraction::Error) { run_with(failing) }
    assert_equal "unreadable_pdf", error.code
  end

  test "a stage's attributes start from their default on every run" do
    reading = stage(10, "reading", fields: {}, attributes: { "read_column" => "set" })
    reading.define_singleton_method(:default_attributes) { { "read_column" => nil } }
    skipped = stage(20, "skipped", fields: {})
    skipped.define_singleton_method(:default_attributes) { { "skipped_column" => [] } }
    skipped.define_method(:applicable?) { false }

    result = run_with(reading, skipped)

    assert_equal({ "read_column" => "set", "skipped_column" => [] }, result.attributes)
  end

  test "masks a card number read as the merchant, whatever the stage" do
    first = stage(10, "first", fields: { "merchant_name" => field("4111 1111 1111 1234") })

    result = run_with(first)

    assert_equal "****1234", result.fields["merchant_name"][:value]
  end

  private
    def field(value, confidence: 0.9)
      { value: value, confidence: confidence }
    end

    def stage(position, source, fields:, text: nil, attributes: {}, settles: [])
      reading = Reading.new(fields: fields, text: text, attributes: attributes, settles: settles)
      Class.new(Stage) do
        define_singleton_method(:position) { position }
        define_singleton_method(:source) { source }
        define_method(:read) { reading }
      end
    end

    def run_with(*stages)
      Receipt::Extraction.stubs(:stages).returns(stages)
      Receipt::Extraction.new(@receipt).run
    end
end
