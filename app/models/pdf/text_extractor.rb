# The text of each page of a PDF, in order. Callers decide how to join the
# pages and how to handle a PDF the reader cannot open; errors propagate.
module Pdf::TextExtractor
  # With max_pages, only those pages are built, so a long PDF costs no more
  # than its first pages and a broken page after them is never read.
  def self.pages(content, max_pages: nil)
    reader = PDF::Reader.new(StringIO.new(content.to_s))
    return reader.pages.map(&:text) unless max_pages

    (1..[ reader.page_count, max_pages ].min).map { |number| reader.page(number).text }
  rescue PDF::Reader::InvalidPageError
    raise PDF::Reader::MalformedPDFError, "Missing data for a page"
  end
end
