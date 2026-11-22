# Builds a one-page PDF whose text layer holds the given lines, for tests that
# read receipts without shipping binary fixtures. `attachments` embeds files the
# way ZUGFeRD and Factur-X do: in the EmbeddedFiles name tree and as associated
# files (/AF), Flate-compressed unless `compress: false`. `extra_objects` are
# appended after them (numbered from 6 without attachments) and `catalog_extra`
# is added to the catalog, for hand-built structures.
module ReceiptPdfHelper
  def receipt_pdf(lines, attachments: {}, compress: true, extra_objects: [], catalog_extra: "")
    escaped = lines.map { |line| line.gsub(/[\\()]/) { |char| "\\#{char}" } }
    text = escaped.each_with_index.map { |line, index| "BT /F1 10 Tf 40 #{780 - index * 14} Td (#{line}) Tj ET" }.join("\n")
    # Non-ASCII characters become "?", as a plain Type1 font has no Unicode map.
    text = text.encode("BINARY", invalid: :replace, undef: :replace)
    objects = [
      nil,
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{text.bytesize} >>\nstream\n#{text}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    ]

    specs = attachments.map do |name, content|
      data = compress ? Zlib::Deflate.deflate(content) : content
      filter = compress ? " /Filter /FlateDecode" : ""
      objects << "<< /Type /EmbeddedFile /Subtype /text#2Fxml#{filter} /Length #{data.bytesize} >>\nstream\n".b + data.b + "\nendstream".b
      objects << "<< /Type /Filespec /F (#{name}) /UF (#{name}) /AFRelationship /Alternative /EF << /F #{objects.size} 0 R /UF #{objects.size} 0 R >> >>"
      [ name, objects.size ]
    end
    embedded = specs.any? ? " /Names << /EmbeddedFiles << /Names [#{specs.map { |name, ref| "(#{name}) #{ref} 0 R" }.join(' ')}] >> >> /AF [#{specs.map { |_, ref| "#{ref} 0 R" }.join(' ')}]" : ""
    objects.concat(extra_objects)
    objects[0] = "<< /Type /Catalog /Pages 2 0 R#{embedded}#{catalog_extra} >>"

    pdf = "%PDF-1.7\n".b
    offsets = objects.each_with_index.map do |object, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n".b << object.b << "\nendobj\n".b
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    pdf
  end

  def e_invoice_xml(name)
    file_fixture("e_invoices/#{name}.xml").read
  end

  def uploaded_receipt(content, filename: "receipt.pdf", content_type: "application/pdf")
    Rack::Test::UploadedFile.new(StringIO.new(content.dup), content_type, true, original_filename: filename)
  end
end
