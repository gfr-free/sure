require "test_helper"

class Pdf::EmbeddedFilesTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  test "lists compressed and uncompressed embedded files and reads them on demand" do
    compressed = receipt_pdf([ "Invoice" ], attachments: { "factur-x.xml" => "<a>compressed</a>" })
    plain = receipt_pdf([ "Invoice" ], attachments: { "notes.xml" => "<a>plain</a>" }, compress: false)

    assert_equal({ "factur-x.xml" => "<a>compressed</a>" }, read_all(compressed))
    assert_equal({ "notes.xml" => "<a>plain</a>" }, read_all(plain))
  end

  test "stops inflating a file at the size limit" do
    bomb = receipt_pdf([ "Invoice" ], attachments: { "factur-x.xml" => "<a>#{'x' * 200_000}</a>", "small.xml" => "<b/>" })

    assert_equal({ "factur-x.xml" => nil, "small.xml" => "<b/>" }, read_all(bomb, max_size: 10.kilobytes))
  end

  test "walks a name tree that repeats its own nodes only once per node" do
    looping = receipt_pdf([ "Invoice" ], extra_objects: [ "<< /Kids [#{([ '6 0 R' ] * 50).join(' ')}] >>" ],
                                       catalog_extra: " /Names << /EmbeddedFiles 6 0 R >>")

    assert_equal [], Timeout.timeout(5) { Pdf::EmbeddedFiles.list(looping) }
  end

  test "lists nothing for a PDF without embedded files or one it cannot read" do
    assert_equal [], Pdf::EmbeddedFiles.list(receipt_pdf([ "Total 1.00" ]))
    assert_equal [], Pdf::EmbeddedFiles.list("%PDF-1.4 broken")
  end

  private
    def read_all(pdf, max_size: 1.kilobyte)
      Pdf::EmbeddedFiles.list(pdf).to_h { |file| [ file.name, file.read(max_size: max_size) ] }
    end
end
