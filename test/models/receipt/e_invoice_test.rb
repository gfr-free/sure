require "test_helper"

class Receipt::EInvoiceTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  test "reads a CII invoice (ZUGFeRD 2, Factur-X, XRechnung CII)" do
    fields = values(Receipt::EInvoice.parse(e_invoice_xml("cii_invoice")))

    assert_equal "Demo Supplies GmbH", fields["merchant_name"]
    assert_equal Date.new(2026, 11, 5), fields["date"]
    assert_equal BigDecimal("119.00"), fields["amount"]
    assert_equal "EUR", fields["currency"]
    assert_equal "DEMO-2026-0042", fields["invoice_number"]
    assert_equal Date.new(2026, 11, 19), fields["due_date"]
    assert_equal BigDecimal("19.00"), fields["tax_amount"], "the tax in the invoice currency, not the tax currency"
    assert_equal [ 1.0 ], Receipt::EInvoice.parse(e_invoice_xml("cii_invoice")).values.map { |value| value[:confidence] }.uniq
  end

  test "reads a ZUGFeRD 1 invoice" do
    fields = values(Receipt::EInvoice.parse(e_invoice_xml("zugferd1_invoice")))

    assert_equal "Demo Print KG", fields["merchant_name"]
    assert_equal Date.new(2026, 10, 1), fields["date"]
    assert_equal BigDecimal("10.81"), fields["amount"]
    assert_equal "CHF", fields["currency"]
    assert_equal BigDecimal("0.81"), fields["tax_amount"]
  end

  test "reads a UBL invoice (XRechnung UBL, Peppol)" do
    fields = values(Receipt::EInvoice.parse(e_invoice_xml("ubl_invoice")))

    assert_equal "Demo Energy AG", fields["merchant_name"]
    assert_equal Date.new(2026, 10, 30), fields["date"]
    assert_equal BigDecimal("49.98"), fields["amount"]
    assert_equal "EUR", fields["currency"]
    assert_equal "DEMO-UBL-7", fields["invoice_number"]
    assert_equal Date.new(2026, 11, 13), fields["due_date"]
    assert_equal BigDecimal("7.98"), fields["tax_amount"]
  end

  test "a credit note keeps merchant, date and number but no amount" do
    fields = values(Receipt::EInvoice.parse(e_invoice_xml("ubl_credit_note")))

    assert_equal "Demo Energy", fields["merchant_name"]
    assert_equal Date.new(2026, 11, 2), fields["date"]
    assert_equal "DEMO-CN-3", fields["invoice_number"]
    assert_nil fields["amount"]
    assert_nil fields["tax_amount"]

    cii_credit_note = e_invoice_xml("cii_invoice").sub("<ram:TypeCode>380", "<ram:TypeCode>381")
    assert_nil values(Receipt::EInvoice.parse(cii_credit_note))["amount"]
  end

  test "skips values it cannot trust" do
    xml = e_invoice_xml("cii_invoice")
      .sub("<ram:GrandTotalAmount>119.00", "<ram:GrandTotalAmount>1,19E2")
      .sub('format="102">20261105', 'format="610">202611')
      .sub("<ram:InvoiceCurrencyCode>EUR", "<ram:InvoiceCurrencyCode>XYZ")
    fields = values(Receipt::EInvoice.parse(xml))

    assert_nil fields["amount"]
    assert_nil fields["date"]
    assert_nil fields["currency"]
    assert_equal "Demo Supplies GmbH", fields["merchant_name"]
  end

  test "ignores XML that is not an e-invoice, broken XML and documents with a DTD" do
    assert_equal({}, Receipt::EInvoice.parse("<note><to>Demo</to></note>"))
    assert_equal({}, Receipt::EInvoice.parse("<rsm:CrossIndustryInvoice"))
    assert_equal({}, Receipt::EInvoice.parse(""))

    with_entity = e_invoice_xml("cii_invoice")
      .sub("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY seller SYSTEM \"file:///etc/hostname\">]>")
      .sub("Demo Supplies GmbH", "&seller;")
    assert_equal({}, Receipt::EInvoice.parse(with_entity))
  end

  test "refuses a DTD in a UTF-16 document too" do
    xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x [<!ENTITY a \"Demo\">]>" +
      e_invoice_xml("cii_invoice").sub(/\A<\?xml[^>]*>/, "").sub("Demo Supplies GmbH", "&a;")
    utf16 = "\xFF\xFE".b + xml.encode(Encoding::UTF_16LE).b

    assert_equal({}, Receipt::EInvoice.parse(utf16))
    assert_equal "Demo Supplies GmbH", values(Receipt::EInvoice.parse(e_invoice_xml("cii_invoice").encode(Encoding::UTF_16LE).then { |doc| "\xFF\xFE".b + doc.b }))["merchant_name"]
  end

  test "matches the currency of an amount regardless of case" do
    xml = e_invoice_xml("ubl_invoice").gsub('currencyID="EUR"', 'currencyID="eur"').sub(">EUR<", ">eur<")
    fields = values(Receipt::EInvoice.parse(xml))

    assert_equal "EUR", fields["currency"]
    assert_equal BigDecimal("49.98"), fields["amount"]
    assert_equal BigDecimal("7.98"), fields["tax_amount"]
  end

  test "reads the invoice embedded in a ZUGFeRD or Factur-X PDF" do
    pdf = receipt_pdf([ "Invoice DEMO-2026-0042", "Total 999.00" ], attachments: { "factur-x.xml" => e_invoice_xml("cii_invoice") })

    fields = values(Receipt::EInvoice.from_pdf(pdf))

    assert_equal BigDecimal("119.00"), fields["amount"]
    assert_equal "Demo Supplies GmbH", fields["merchant_name"]
  end

  test "prefers the standard's file name over other embedded XML" do
    pdf = receipt_pdf([ "Invoice" ], attachments: {
      "a-other.xml" => e_invoice_xml("ubl_invoice"),
      "zugferd-invoice.xml" => e_invoice_xml("zugferd1_invoice")
    })

    assert_equal "Demo Print KG", values(Receipt::EInvoice.from_pdf(pdf))["merchant_name"]
  end

  test "finds nothing in a plain PDF" do
    assert_equal({}, Receipt::EInvoice.from_pdf(receipt_pdf([ "Total 1.00" ])))
    assert_equal({}, Receipt::EInvoice.from_pdf("%PDF-1.4 broken"))
  end

  private
    def values(fields)
      fields.transform_values { |value| value[:value] }
    end
end
