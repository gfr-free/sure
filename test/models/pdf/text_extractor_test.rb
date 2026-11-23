require "test_helper"

class Pdf::TextExtractorTest < ActiveSupport::TestCase
  setup do
    @content = file_fixture("account_statements/trade_republic_it_2026_04.pdf").binread
  end

  test "returns the text of each page" do
    pages = Pdf::TextExtractor.pages(@content)

    assert pages.any?
    assert_match(/Trade Republic/i, pages.join("\n"))
  end

  test "stops after max_pages without building the later pages" do
    PDF::Reader.any_instance.stubs(:page_count).returns(3)
    PDF::Reader.any_instance.expects(:pages).never
    PDF::Reader.any_instance.expects(:page).with(1).returns(stub(text: "one"))
    PDF::Reader.any_instance.expects(:page).with(2).returns(stub(text: "two"))
    PDF::Reader.any_instance.expects(:page).with(3).never

    assert_equal %w[one two], Pdf::TextExtractor.pages(@content, max_pages: 2)
  end

  test "reports a missing page within max_pages as a malformed PDF" do
    PDF::Reader.any_instance.stubs(:page).raises(PDF::Reader::InvalidPageError)

    assert_raises(PDF::Reader::MalformedPDFError) { Pdf::TextExtractor.pages(@content, max_pages: 2) }
  end

  test "raises for content that is not a PDF" do
    assert_raises(PDF::Reader::MalformedPDFError) { Pdf::TextExtractor.pages("not a pdf") }
  end
end
