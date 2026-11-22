require "test_helper"

class Receipt::QrReaderTest < ActiveSupport::TestCase
  include ReceiptQrHelper

  test "reads a QR code from a photo and keeps its line breaks" do
    payload = epc_payload

    assert_equal [ payload ], Receipt::QrReader.read(receipt_qr_png(payload), content_type: "image/png")
  end

  test "reads a QR code printed in a PDF" do
    payload = german_till_payload

    assert_equal [ payload ], Receipt::QrReader.read(receipt_qr_pdf(payload), content_type: "application/pdf")
  end

  test "returns nothing for an image without a code or a file it cannot decode" do
    assert_empty Receipt::QrReader.read(file_fixture("square-placeholder.png").binread, content_type: "image/png")
    assert_empty Receipt::QrReader.read("not an image", content_type: "image/jpeg")
    assert_empty Receipt::QrReader.read("%PDF-1.4 broken", content_type: "application/pdf")
  end

  test "returns nothing when zbar is not installed" do
    Receipt::ExternalCommand.stubs(:available?).with("zbarimg").returns(false)

    assert_empty Receipt::QrReader.read(receipt_qr_png("BCD"), content_type: "image/png")
  end

  test "commands run without the app's environment and are stopped at the time limit" do
    ENV["RECEIPT_TEST_SECRET"] = "secret"
    output, status = Receipt::ExternalCommand.run("sh", "-c", "echo \"[$RECEIPT_TEST_SECRET]\"", timeout: 5, chdir: Dir.tmpdir)
    assert_equal "[]\n", output
    assert_equal 0, status

    assert_raises(Receipt::ExternalCommand::TimeoutError) do
      Receipt::ExternalCommand.run("sleep", "5", timeout: 0.2, chdir: Dir.tmpdir)
    end
  ensure
    ENV.delete("RECEIPT_TEST_SECRET")
  end
end
