require "test_helper"

class Receipt::AiReadingTest < ActiveSupport::TestCase
  setup { travel_to Date.new(2026, 11, 22) }

  test "maps the answer onto receipt fields with a middle confidence without text" do
    fields = Receipt::AiReading.new({ merchant_name: "  Coffee   House ", total: 12.4, currency: "eur", date: "2026-11-20" }).fields

    assert_equal "Coffee House", fields["merchant_name"][:value]
    assert_equal BigDecimal("12.4"), fields["amount"][:value]
    assert_equal "EUR", fields["currency"][:value]
    assert_equal Date.new(2026, 11, 20), fields["date"][:value]
    assert_equal [ "ai" ], fields.values.map { _1[:source] }.uniq
    assert_equal 0.6, fields["amount"][:confidence]
  end

  test "amount and date found in the read text count as more certain, missing ones as less" do
    text = "Summe 1.234,50 EUR\nDatum 20.11.2026"

    found = Receipt::AiReading.new({ "total" => "1234.50", "date" => "2026-11-20" }, text:).fields
    assert_equal 0.8, found["amount"][:confidence]
    assert_equal 0.8, found["date"][:confidence]

    missing = Receipt::AiReading.new({ "total" => "99.00", "date" => "2026-11-19" }, text:).fields
    assert_equal 0.4, missing["amount"][:confidence]
    assert_equal 0.4, missing["date"][:confidence]
  end

  test "a value printed inside a longer one does not confirm the answer" do
    fields = Receipt::AiReading.new({ "total" => "2.00", "date" => "2026-02-01" }, text: "Summe 12.00\nDatum 11.2.2026").fields

    assert_equal 0.4, fields["amount"][:confidence]
    assert_equal 0.4, fields["date"][:confidence]
  end

  test "keeps tomorrow's date, which is today where the receipt was printed" do
    assert_equal Date.new(2026, 11, 23), Receipt::AiReading.new({ "date" => "2026-11-23" }).fields["date"][:value]
  end

  test "drops values a receipt cannot hold" do
    fields = Receipt::AiReading.new({ merchant_name: "", total: -5, currency: "XYZ", date: "2026-12-24" }).fields
    assert_empty fields

    assert_empty Receipt::AiReading.new({ total: "abc", date: "2020-01-01", currency: "euro" }).fields
    assert_empty Receipt::AiReading.new({ total: nil, date: "not a date", currency: nil }).fields
    assert_empty Receipt::AiReading.new({ total: 12_345_678_901_234_567 }).fields
  end
end
