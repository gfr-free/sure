require "test_helper"

class Receipt::QrParserTest < ActiveSupport::TestCase
  include ReceiptQrHelper

  setup do
    travel_to Time.zone.parse("2026-11-22 12:00")
  end

  test "reads total, date and currency from a German till receipt" do
    result = Receipt::QrParser.parse([ german_till_payload ], timezone: "Europe/Berlin")

    assert_equal BigDecimal("11.59"), result.fields["amount"][:value]
    assert_equal Date.new(2026, 11, 20), result.fields["date"][:value]
    assert_equal "EUR", result.fields["currency"][:value]
    assert_equal 0.95, result.fields["amount"][:confidence]
    assert_nil result.fields["merchant_name"]
    assert_equal [ "tse" ], result.identifiers.map { |identifier| identifier["kind"] }
    assert_match(/\A\h{64}\z/, result.identifiers.first["digest"])
    assert_not_equal result.identifiers, Receipt::QrParser.parse([ german_till_payload(serial: "KASSE-02") ]).identifiers
  end

  test "dates a German till receipt in the family's time zone" do
    payload = german_till_payload(time: "2026-11-20T23:30:00.000Z")

    assert_equal Date.new(2026, 11, 21), Receipt::QrParser.parse([ payload ], timezone: "Europe/Berlin").fields["date"][:value]
    assert_equal Date.new(2026, 11, 20), Receipt::QrParser.parse([ payload ], timezone: "America/New_York").fields["date"][:value]
  end

  test "ignores till records that are not sales and refunds without a positive total" do
    assert_empty Receipt::QrParser.parse([ german_till_payload(type: "AVTraining") ]).fields
    assert_nil Receipt::QrParser.parse([ german_till_payload(gross: "-8.40_0.00_0.00_0.00_0.00") ]).fields["amount"]
    assert_empty Receipt::QrParser.parse([ "V0;KASSE;SonstigerVorgang;x;1;2;3;4;5;6;7;8" ]).fields
  end

  test "keeps the amount but drops an implausible date" do
    result = Receipt::QrParser.parse([ german_till_payload(time: "2019-07-10T18:41:04.000Z") ])

    assert_equal BigDecimal("11.59"), result.fields["amount"][:value]
    assert_nil result.fields["date"]
  end

  test "reads an Austrian till receipt" do
    payload = "_R1-AT1_DEMO-KASSE-1_83469_2026-11-19T09:15:42_12,30_3,20_0,00_0,00_0,00_jEdB6Q==_3D0A1E2B_Pb8ODkjqNfs=_signature=="

    result = Receipt::QrParser.parse([ payload ])

    assert_equal BigDecimal("15.50"), result.fields["amount"][:value]
    assert_equal Date.new(2026, 11, 19), result.fields["date"][:value]
    assert_equal [ { "kind" => "rksv", "digest" => Digest::SHA256.hexdigest("rksv:3D0A1E2B:DEMO-KASSE-1") } ], result.identifiers
  end

  test "reads payee and amount from a GiroCode and keeps only the IBAN ending" do
    result = Receipt::QrParser.parse([ epc_payload ])

    assert_equal "Stadtwerke Demo GmbH", result.fields["merchant_name"][:value]
    assert_equal BigDecimal("86.40"), result.fields["amount"][:value]
    assert_equal "EUR", result.fields["currency"][:value]
    assert_nil result.fields["date"]
    assert_equal [ { "kind" => "payee", "digest" => Digest::SHA256.hexdigest("payee:DE2051:stadtwerke demo gmbh") } ], result.identifiers
  end

  test "a GiroCode without an amount still names the payee" do
    result = Receipt::QrParser.parse([ epc_payload(amount: "") ])

    assert_equal "Stadtwerke Demo GmbH", result.fields["merchant_name"][:value]
    assert_nil result.fields["amount"]
  end

  test "reads a Swiss QR-bill" do
    lines = [ "SPC", "0200", "1", ReceiptQrHelper::DEMO_SWISS_IBAN, "S", "Demo Verlag AG", "Musterstrasse", "1", "8000", "Zürich", "CH",
              "", "", "", "", "", "", "", "49.90", "CHF", "S", "Kunde", "", "", "", "", "", "QRR", "210000000003139471430009017", "", "EPD" ]

    result = Receipt::QrParser.parse([ lines.join("\r\n") ])

    assert_equal "Demo Verlag AG", result.fields["merchant_name"][:value]
    assert_equal BigDecimal("49.90"), result.fields["amount"][:value]
    assert_equal "CHF", result.fields["currency"][:value]
  end

  test "a till receipt's signed total wins over a transfer code's amount" do
    result = Receipt::QrParser.parse([ epc_payload, german_till_payload ])

    assert_equal BigDecimal("11.59"), result.fields["amount"][:value]
    assert_equal "Stadtwerke Demo GmbH", result.fields["merchant_name"][:value]
    assert_equal 2, result.identifiers.size
  end

  test "ignores other QR codes" do
    result = Receipt::QrParser.parse([ "https://example.com/receipt/123", "BCD\nbroken", "_R1-AT1_short" ])

    assert_empty result.fields
    assert_empty result.identifiers
  end
end
