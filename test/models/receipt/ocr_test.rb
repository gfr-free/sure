require "test_helper"

class Receipt::OcrTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  TSV_HEADER = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"

  setup do
    Receipt::Ocr.reset_cache!
  end

  teardown do
    Receipt::Ocr.reset_cache!
  end

  test "uses German and English plus the locale's pack when installed" do
    Receipt::Ocr.stubs(:installed_languages).returns(%w[deu eng fra osd])

    assert_equal %w[deu eng], Receipt::Ocr.languages
    assert_equal %w[deu eng fra], Receipt::Ocr.languages(locale: "fr")
    assert_equal %w[deu eng], Receipt::Ocr.languages(locale: "es")
    assert Receipt::Ocr.available?
  end

  test "is unavailable without tesseract or without a usable language pack" do
    Receipt::Ocr.stubs(:run).raises(Receipt::Ocr::Error.new("ocr_unavailable"))
    assert_equal [], Receipt::Ocr.installed_languages
    assert_not Receipt::Ocr.available?
    assert_not Receipt::Ocr.pdf_renderer_installed?

    Receipt::Ocr.reset_cache!
    Receipt::Ocr.unstub(:run)
    Receipt::Ocr.stubs(:run).returns([ "List of available languages (1):\nosd\n", "", stub(success?: true) ])
    assert_equal %w[osd], Receipt::Ocr.installed_languages
    assert_not Receipt::Ocr.available?
  end

  test "a failed probe is retried after a minute, a successful one is kept" do
    Receipt::Ocr.expects(:run).with("tesseract", "--list-langs", timeout: 10).twice
                .raises(Receipt::Ocr::Error.new("ocr_timeout")).then
                .returns([ "List of available languages (2):\ndeu\neng\n", "", stub(success?: true) ])

    assert_equal [], Receipt::Ocr.installed_languages
    assert_equal [], Receipt::Ocr.installed_languages
    travel 2.minutes do
      assert_equal %w[deu eng], Receipt::Ocr.installed_languages
      assert_equal %w[deu eng], Receipt::Ocr.installed_languages
    end
  end

  test "joins the words of each line and averages the word confidence" do
    Receipt::Ocr.stubs(:installed_languages).returns(%w[deu eng])
    tsv = TSV_HEADER + [
      "1\t1\t0\t0\t0\t0\t0\t0\t100\t100\t-1\t",
      "5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t96\tMUSTERMARKT",
      "5\t1\t1\t1\t2\t1\t0\t0\t10\t10\t90\tSUMME",
      "5\t1\t1\t1\t2\t2\t0\t0\t10\t10\t80\tEUR",
      "5\t1\t1\t1\t2\t3\t0\t0\t10\t10\t70\t12,3O",
      "5\t1\t1\t1\t2\t4\t0\t0\t10\t10\t-1\t "
    ].join("\n")
    Receipt::Ocr.expects(:run).with { |*args, **| args.first == "tesseract" && args.include?("deu+eng") && args.include?("tsv") }
                .returns([ tsv, "", stub(success?: true) ])

    result = Receipt::Ocr.new.read_image(file_fixture("square-placeholder.png").binread, content_type: "image/png")

    assert_equal "MUSTERMARKT\nSUMME EUR 12,30", result.text
    assert_equal 0.84, result.confidence
  end

  test "an image is decoded only by the loader for its declared type" do
    Receipt::Ocr.stubs(:installed_languages).returns(%w[eng])
    Receipt::Ocr.expects(:run).never
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>)
    png = file_fixture("square-placeholder.png").binread

    [ [ "not an image", "image/png" ], [ svg, "image/png" ], [ png, "image/jpeg" ], [ png, "image/svg+xml" ] ].each do |content, type|
      error = assert_raises(Receipt::Ocr::Error) { Receipt::Ocr.new.read_image(content, content_type: type) }
      assert_equal "unreadable_image", error.code
    end
  end

  test "a 16-bit image keeps its contrast in the prepared copy" do
    gray = (Vips::Image.black(400, 200) + 60_000).cast(:ushort).copy(interpretation: :grey16)
    gray = gray.draw_rect(5_000, 100, 80, 200, 40, fill: true)
    prepared = Tempfile.create([ "prepared", ".png" ]) do |file|
      Receipt::Ocr.new.send(:prepare_image, Vips::Image.pngload_buffer(gray.pngsave_buffer(bitdepth: 16)), file.path)
      Vips::Image.new_from_file(file.path).copy_memory
    end

    assert_equal :uchar, prepared.format
    assert_operator prepared.min, :<, 50
  end

  test "a transparent 16-bit image is flattened onto white" do
    # Black ink everywhere, opaque only where the text is: transparent paper.
    alpha = Vips::Image.black(400, 200).cast(:ushort).draw_rect(65_535, 100, 80, 200, 40, fill: true)
    image = Vips::Image.black(400, 200).bandjoin(alpha).cast(:ushort).copy(interpretation: :grey16)
    prepared = Tempfile.create([ "prepared", ".png" ]) do |file|
      Receipt::Ocr.new.send(:prepare_image, Vips::Image.pngload_buffer(image.pngsave_buffer(bitdepth: 16)), file.path)
      Vips::Image.new_from_file(file.path).copy_memory
    end

    assert_operator prepared.percent(50), :>, 200
    assert_operator prepared.min, :<, 50
  end

  test "later PDF pages only get the time left in the budget, and a page cut off keeps the ones read" do
    Receipt::Ocr.stubs(:installed_languages).returns(%w[eng])
    Receipt::Ocr.stubs(:run).returns([ "", "", stub(success?: true) ])
    Dir.stubs(:glob).returns(%w[page-1.png page-2.png])
    ocr = Receipt::Ocr.new
    ocr.stubs(:prepare_image)
    Vips::Image.stubs(:pngload)
    ocr.stubs(:monotonic_now).returns(0, 80, 80)
    ocr.expects(:recognize).with(anything, timeout: Receipt::Ocr::COMMAND_TIMEOUT).returns({ text: "SUMME 4,70", confidences: [ 90.0 ] })
    ocr.expects(:recognize).with(anything, timeout: 10).raises(Receipt::Ocr::Error.new("ocr_timeout"))

    result = ocr.read_pdf("%PDF-1.4", max_pages: 2)

    assert_equal "SUMME 4,70", result.text
    assert_equal 0.9, result.confidence
  end

  test "refuses an image whose canvas is larger than the pixel limit" do
    Receipt::Ocr.stubs(:installed_languages).returns(%w[eng])
    Receipt::Ocr.expects(:run).never
    huge = Vips::Image.black(7100, 7100).pngsave_buffer(compression: 9)

    error = assert_raises(Receipt::Ocr::Error) { Receipt::Ocr.new.read_image(huge, content_type: "image/png") }
    assert_equal "image_too_large", error.code
  end

  test "programs run without the app's environment" do
    ENV["RECEIPT_OCR_TEST_SECRET"] = "do-not-leak"
    stdout, _stderr, status = Receipt::Ocr.run("env")

    assert status.success?
    assert_no_match(/do-not-leak/, stdout)
    assert_match(/OMP_THREAD_LIMIT=1/, stdout)
  ensure
    ENV.delete("RECEIPT_OCR_TEST_SECRET")
  end

  test "a program that runs too long is stopped" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Receipt::Ocr::Error) { Receipt::Ocr.run("sleep", "10", timeout: 0.2) }

    assert_equal "ocr_timeout", error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  test "a missing program reads as unavailable" do
    error = assert_raises(Receipt::Ocr::Error) { Receipt::Ocr.run("sure-no-such-ocr-program") }
    assert_equal "ocr_unavailable", error.code
  end

  test "reads a photo of a receipt with the installed tesseract" do
    require_ocr!

    date = Date.current - 3
    photo = receipt_photo([ "MUSTERMARKT GMBH", "Hauptstrasse 1", "Brot 3,50", "Milch 1,20", "SUMME EUR 4,70",
                            "Datum #{date.strftime('%d.%m.%Y')} 14:05" ])

    result = Receipt::Ocr.new.read_image(photo, content_type: "image/png")
    fields = Receipt::TextParser.parse(result.text, currency_hint: "EUR")

    assert_equal BigDecimal("4.70"), fields.dig("amount", :value)
    assert_equal date, fields.dig("date", :value)
    assert_operator result.confidence, :>, 0.5
  end

  test "reads a scanned PDF with the installed tesseract" do
    require_ocr!(pdf: true)

    date = Date.current - 5
    pdf = Vips::Image.new_from_buffer(receipt_photo([ "Rechnung", "Gesamtbetrag 19,99 EUR", "Rechnungsdatum #{date.strftime('%d.%m.%Y')}" ]), "")
    scan = Tempfile.create([ "scan", ".png" ]) do |file|
      pdf.pngsave(file.path)
      image_pdf(file.path)
    end

    result = Receipt::Ocr.new.read_pdf(scan, max_pages: 2)
    fields = Receipt::TextParser.parse(result.text, currency_hint: "EUR")

    assert_equal BigDecimal("19.99"), fields.dig("amount", :value)
    assert_equal date, fields.dig("date", :value)
  end

  private
    # Skips without Tesseract or pdftoppm locally; fails in CI, which installs
    # them, so a broken probe cannot silently skip these tests there.
    def require_ocr!(pdf: false)
      missing = []
      missing << "tesseract with German and English" unless (%w[deu eng] - Receipt::Ocr.installed_languages).empty?
      missing << "pdftoppm" if pdf && !Receipt::Ocr.pdf_renderer_installed?
      return if missing.empty?

      message = "#{missing.to_sentence} not installed"
      ENV["RECEIPT_OCR_REQUIRED"].present? ? flunk(message) : skip(message)
    end

    # A grey photo-like PNG of the lines, rendered with libvips.
    def receipt_photo(lines)
      text = Vips::Image.text(lines.join("\n"), font: "DejaVu Sans Mono 24", dpi: 150)
      canvas = text.embed(60, 60, text.width + 120, text.height + 120)
      ((canvas * -0.7) + 230).cast(:uchar).pngsave_buffer
    end

    # A PDF whose only content is the image, like a scan without a text layer.
    # libvips cannot write PDF, so the pixels go in as an uncompressed grey image.
    def image_pdf(png_path)
      image = Vips::Image.new_from_file(png_path).extract_band(0)
      pixels = image.write_to_memory
      width, height = image.width, image.height
      content = "q #{width} 0 0 #{height} 0 0 cm /Im1 Do Q"
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>",
        "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
        "<< /Type /XObject /Subtype /Image /Width #{width} /Height #{height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Length #{pixels.bytesize} >>\nstream\n".b + pixels + "\nendstream".b
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
end
