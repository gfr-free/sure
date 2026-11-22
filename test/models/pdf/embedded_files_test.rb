require "test_helper"

class Pdf::EmbeddedFilesTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  test "reads compressed and uncompressed embedded files" do
    compressed = receipt_pdf([ "Invoice" ], attachments: { "factur-x.xml" => "<a>compressed</a>" })
    plain = receipt_pdf([ "Invoice" ], attachments: { "notes.xml" => "<a>plain</a>" }, compress: false)

    assert_equal({ "factur-x.xml" => "<a>compressed</a>" }, Pdf::EmbeddedFiles.read(compressed, max_size: 1.kilobyte))
    assert_equal({ "notes.xml" => "<a>plain</a>" }, Pdf::EmbeddedFiles.read(plain, max_size: 1.kilobyte))
  end

  test "stops inflating a file at the size limit" do
    bomb = receipt_pdf([ "Invoice" ], attachments: { "factur-x.xml" => "<a>#{'x' * 200_000}</a>", "small.xml" => "<b/>" })

    assert_equal({ "small.xml" => "<b/>" }, Pdf::EmbeddedFiles.read(bomb, max_size: 10.kilobytes))
  end

  test "returns nothing for a PDF without embedded files or one it cannot read" do
    assert_equal({}, Pdf::EmbeddedFiles.read(receipt_pdf([ "Total 1.00" ]), max_size: 1.kilobyte))
    assert_equal({}, Pdf::EmbeddedFiles.read("%PDF-1.4 broken", max_size: 1.kilobyte))
  end
end
