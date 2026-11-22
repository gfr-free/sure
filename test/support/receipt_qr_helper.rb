# Draws QR codes as PNG files and as one-page PDFs, for tests that read receipts
# without shipping binary fixtures.
module ReceiptQrHelper
  def receipt_qr_png(payload, size: 360)
    RQRCode::QRCode.new(payload).as_png(size: size, border_modules: 4).to_s
  end

  # The QR code is a grey image on an A4 page.
  def receipt_qr_pdf(payload, module_pixels: 4)
    modules = RQRCode::QRCode.new(payload).modules
    border = 4
    count = modules.size + border * 2
    edge = count * module_pixels
    pixels = (0...edge).map do |y|
      row = y / module_pixels - border
      (0...edge).map do |x|
        column = x / module_pixels - border
        dark = row.between?(0, modules.size - 1) && column.between?(0, modules.size - 1) && modules[row][column]
        dark ? 0.chr : 255.chr
      end.join
    end.join.b

    content = "q 200 0 0 200 40 560 cm /Im1 Do Q"
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>",
      "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
      "<< /Type /XObject /Subtype /Image /Width #{edge} /Height #{edge} /ColorSpace /DeviceGray /BitsPerComponent 8 /Length #{pixels.bytesize} >>\nstream\n#{pixels}\nendstream"
    ]

    pdf = "%PDF-1.4\n".b
    offsets = objects.each_with_index.map do |object, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n".b << object.b << "\nendobj\n".b
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset).b }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
    pdf
  end

  def german_till_payload(gross: "8.40_3.19_0.00_0.00_0.00", type: "Beleg", time: "2026-11-20T17:41:04.000Z", serial: "KASSE-01", public_key: "BHhWOeisRpPBTGQ1W4VUH95TXx2GA")
    "V0;#{serial};Kassenbeleg-V1;#{type}^#{gross}^11.59:Bar;18;112;#{time};#{time};ecdsa-plain-SHA256;unixTime;MEQCIAy4P9k+7x9saDO0uRZ4El8Q==;#{public_key}"
  end

  def epc_payload(name: "Stadtwerke Demo GmbH", iban: "DE02120300000000202051", amount: "EUR86.40")
    [ "BCD", "002", "1", "SCT", "BYLADEM1001", name, iban, amount, "", "RE-2026-1104", "Abschlag November" ].join("\n")
  end
end
