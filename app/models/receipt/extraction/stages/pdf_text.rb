# frozen_string_literal: true

# The text layer of a PDF, read with Receipt::TextParser.
class Receipt::Extraction::Stages::PdfText < Receipt::Extraction::Stage
  def self.position
    30
  end

  def self.source
    "pdf_text"
  end

  def applicable?
    receipt.pdf?
  end

  def read
    text_reading(extraction.pdf_text)
  end
end
