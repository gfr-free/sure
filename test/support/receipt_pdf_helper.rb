# Builds a one-page PDF whose text layer holds the given lines, for tests that
# read receipts without shipping binary fixtures.
module ReceiptPdfHelper
  def receipt_pdf(lines)
    escaped = lines.map { |line| line.gsub(/[\\()]/) { |char| "\\#{char}" } }
    text = escaped.each_with_index.map { |line, index| "BT /F1 10 Tf 40 #{780 - index * 14} Td (#{line}) Tj ET" }.join("\n")
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{text.bytesize} >>\nstream\n#{text}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    ]

    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    pdf.encode("BINARY", invalid: :replace, undef: :replace)
  end

  def uploaded_receipt(content, filename: "receipt.pdf", content_type: "application/pdf")
    Rack::Test::UploadedFile.new(StringIO.new(content.dup), content_type, true, original_filename: filename)
  end
end
