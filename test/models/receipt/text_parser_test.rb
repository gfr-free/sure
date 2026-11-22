require "test_helper"

class Receipt::TextParserTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 11, 22)
  end

  test "reads a German supermarket receipt" do
    fields = parse(<<~TEXT, merchant_names: [ "REWE" ])
      REWE Markt GmbH
      Musterstrasse 1
      Bio Milch                 1,29
      Brot                      2,49
      Zwischensumme            19,98
      SUMME EUR                23,47
      EC-Karte                 23,47
      MwSt 7%                   1,54
      Datum 21.11.2026 18:42
    TEXT

    assert_equal BigDecimal("23.47"), fields["amount"][:value]
    assert_equal 0.9, fields["amount"][:confidence]
    assert_equal "EUR", fields["currency"][:value]
    assert_equal Date.new(2026, 11, 21), fields["date"][:value]
    assert_equal "REWE", fields["merchant_name"][:value]
    assert_equal 0.8, fields["merchant_name"][:confidence]
  end

  test "prefers the amount to pay over a plain total" do
    fields = parse(<<~TEXT)
      Example Services Ltd
      Invoice date: 2026-11-03
      Total 100.00 GBP
      Total due 120.00 GBP
    TEXT

    assert_equal BigDecimal("120.00"), fields["amount"][:value]
    assert_equal "GBP", fields["currency"][:value]
    assert_equal Date.new(2026, 11, 3), fields["date"][:value]
    assert_equal "Example Services Ltd", fields["merchant_name"][:value]
    assert_equal 0.3, fields["merchant_name"][:confidence]
  end

  test "reads an amount on the line after its label" do
    fields = parse("Rechnungsbetrag\n1.234,56 EUR\n")

    assert_equal BigDecimal("1234.56"), fields["amount"][:value]
  end

  test "skips tax, subtotal and change lines" do
    fields = parse("Netto 10,00\nMwSt 1,90\nRueckgeld 8,10\nGesamt 11,90\n")

    assert_equal BigDecimal("11.90"), fields["amount"][:value]
    assert_equal 0.7, fields["amount"][:confidence]
  end

  test "reads totals of a thousand or more without a grouping separator" do
    assert_equal BigDecimal("1234.56"), parse("Summe 1234,56\n")["amount"][:value]
    assert_equal BigDecimal("1234.56"), parse("Total 1,234.56\n")["amount"][:value]
  end

  test "takes the first amount after the label, not an included tax" do
    assert_equal BigDecimal("119.00"), parse("Total 119.00 EUR (incl. VAT 19.00 EUR)\n")["amount"][:value]
    assert_equal BigDecimal("5.80"), parse("5,80 EUR Summe\n")["amount"][:value]
  end

  test "keeps a total that says what it includes" do
    assert_equal BigDecimal("23.80"), parse("Netto 20,00\nMwSt 3,80\nGesamtbetrag inkl. MwSt 23,80\n")["amount"][:value]
    assert_equal BigDecimal("120.00"), parse("Sous-total 100,00\nTVA 20,00\nNet à payer 120,00\n")["amount"][:value]
    assert_equal BigDecimal("50.00"), parse("Total 50.00\nTotal VAT 8.00\n")["amount"][:value]
  end

  test "falls back to the largest amount with low confidence" do
    fields = parse("Kaffee 3,20\nKuchen 4,50\n")

    assert_equal BigDecimal("4.50"), fields["amount"][:value]
    assert_equal 0.3, fields["amount"][:confidence]
  end

  test "uses the currency hint only when nothing in the text names one" do
    assert_equal({ value: "EUR", confidence: 0.5 }, parse("Summe 5,00\n", currency_hint: "EUR")["currency"])
    assert_equal "CHF", parse("Total CHF 5.00\n", currency_hint: "EUR")["currency"][:value]
  end

  test "reads currency only next to an amount" do
    fields = parse("ALL PRICES INCL. VAT\nSumme 5,00\n", currency_hint: "EUR")

    assert_equal "EUR", fields["currency"][:value]
    assert_equal 0.5, fields["currency"][:confidence]
  end

  test "reads slash dates month first for a dollar hint" do
    assert_equal Date.new(2026, 3, 4), parse("Date 03/04/2026\n", currency_hint: "USD")["date"][:value]
    assert_equal Date.new(2026, 4, 3), parse("Datum 03/04/2026\n", currency_hint: "EUR")["date"][:value]
  end

  test "reads slash dates by the currency printed on the receipt, not the hint" do
    assert_equal Date.new(2026, 4, 3), parse("Total 5,00 EUR\nDate 03/04/2026\n", currency_hint: "USD")["date"][:value]
  end

  test "a zero total leaves the amount blank instead of taking the change" do
    fields = parse("Total 0.00\nCash 50.00\nChange 50.00\n")

    assert_nil fields["amount"]
  end

  test "the fallback skips change and tax lines" do
    assert_equal BigDecimal("12.00"), parse("Coffee 12.00\nChange 38.00\n")["amount"][:value]
  end

  test "ignores amounts too large to store" do
    assert_nil parse("Total 9999999999999999.00\n")["amount"]
  end

  test "ignores dates in the future or older than two years" do
    fields = parse("Gueltig bis 31.12.2027\nAlt 01.01.2020\nKauf 05.11.2026\n")

    assert_equal Date.new(2026, 11, 5), fields["date"][:value]
    assert_equal 0.6, fields["date"][:confidence]
  end

  test "reads two-digit years" do
    assert_equal Date.new(2026, 11, 20), parse("20.11.26 09:15\n")["date"][:value]
  end

  test "returns nothing for text without receipt data" do
    assert_equal({}, parse("12345\n"))
  end

  test "masks card numbers and IBANs" do
    masked = Receipt::TextParser.mask("Karte 4111 1111 1111 1234\nIBAN DE89 3704 0044 0532 0130 00")

    assert_includes masked, "****1234"
    assert_includes masked, "****3000"
    assert_not_includes masked, "4111"
    assert_not_includes masked, "3704"
  end

  private
    def parse(text, currency_hint: nil, merchant_names: [])
      Receipt::TextParser.parse(text, currency_hint:, merchant_names:)
    end
end
