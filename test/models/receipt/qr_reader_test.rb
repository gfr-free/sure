require "test_helper"

class Receipt::QrReaderTest < ActiveSupport::TestCase
  include ReceiptQrHelper

  test "reads a QR code from a photo and keeps its line breaks" do
    payload = epc_payload

    assert_equal [ payload ], Receipt::QrReader.read(receipt_qr_png(payload), content_type: "image/png")
  end

  test "reads a GiroCode in Latin-1 as UTF-8" do
    payload = epc_payload(name: "Müller Demo GmbH").sub("\n1\n", "\n2\n")
    png = RQRCode::QRCode.new(payload.encode("ISO-8859-1").b, mode: :byte_8bit).as_png(size: 360).to_s

    assert_includes Receipt::QrReader.read(png, content_type: "image/png").first, "Müller Demo GmbH"
  end

  test "reads a phone photo that is stored sideways with an EXIF orientation" do
    payload = german_till_payload
    image = Vips::Image.new_from_buffer(receipt_qr_png(payload), "").colourspace(:srgb).rot(:d270)
    image = image.mutate { |mutable| mutable.set_type!(GObject::GINT_TYPE, "orientation", 6) }

    assert_equal [ payload ], Receipt::QrReader.read(image.jpegsave_buffer(Q: 95), content_type: "image/jpeg")
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

    assert_raises(Receipt::ExternalCommand::Error) do
      Receipt::ExternalCommand.run("sh", "-c", "kill -9 $$", timeout: 5, chdir: Dir.tmpdir)
    end
  ensure
    ENV.delete("RECEIPT_TEST_SECRET")
  end
end
