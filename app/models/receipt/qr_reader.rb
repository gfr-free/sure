# frozen_string_literal: true

require "base64"
require "tmpdir"

# Finds the QR codes on a receipt photo or PDF and returns their contents.
#
# Images are decoded by libvips first (with a pixel limit, turned upright by
# their EXIF tag, grey, at most MAX_EDGE pixels long) and handed to zbarimg as a
# PNG Sure wrote itself, so zbar's own image loader never parses an upload. PDFs
# are rendered page by page with pdftoppm.
class Receipt::QrReader
  PROGRAMS = %w[zbarimg pdftoppm].freeze
  MAX_PIXELS = 50_000_000
  MAX_EDGE = 3000
  MAX_PDF_PAGES = 3
  PDF_PAGE_EDGE = 2400
  MAX_CODES = 10
  TIMEOUT = 20

  def self.available?
    Receipt::ExternalCommand.available?("zbarimg")
  end

  def self.read(content, content_type:)
    new(content, content_type:).read
  end

  def initialize(content, content_type:)
    @content = content
    @content_type = content_type
  end

  # Returns the decoded text of each QR code, in the order zbar found them.
  def read
    return [] unless self.class.available?

    Dir.mktmpdir("receipt-qr") do |dir|
      images = @content_type == "application/pdf" ? render_pdf(dir) : [ normalized_image(dir) ].compact
      return [] if images.empty?

      scan(images, dir)
    end
  end

  private
    def normalized_image(dir)
      require "vips"
      # Random access: turning a photo upright by its EXIF tag reads out of order.
      image = Vips::Image.new_from_buffer(@content, "")
      return nil if image.width * image.height > MAX_PIXELS

      image = image.autorot
      image = image.flatten(background: 255) if image.has_alpha?
      image = image.colourspace(:b_w)
      image = image.extract_band(0) if image.bands > 1
      scale = MAX_EDGE.to_f / [ image.width, image.height ].max
      image = image.resize(scale) if scale < 1

      path = File.join(dir, "receipt.png")
      image.pngsave(path)
      path
    rescue LoadError, Vips::Error
      nil
    end

    def render_pdf(dir)
      return [] unless Receipt::ExternalCommand.available?("pdftoppm")

      File.binwrite(File.join(dir, "receipt.pdf"), @content)
      Receipt::ExternalCommand.run("pdftoppm", "-gray", "-png", "-f", "1", "-l", MAX_PDF_PAGES.to_s,
                                   "-scale-to", PDF_PAGE_EDGE.to_s, "receipt.pdf", "page", timeout: TIMEOUT, chdir: dir)
      Dir.glob(File.join(dir, "page*.png")).sort
    end

    # zbarimg exits 4 when at least one image has no code, so a code on page 1
    # still counts when page 2 has none. Its XML output keeps line breaks inside
    # a code intact, which the plain output would not.
    def scan(images, dir)
      output, status = Receipt::ExternalCommand.run("zbarimg", "--quiet", "--xml", "-Sdisable", "-Sqrcode.enable",
                                                    *images.map { |path| File.basename(path) }, timeout: TIMEOUT, chdir: dir)
      return [] unless [ 0, 4 ].include?(status)

      Nokogiri::XML(output).remove_namespaces!.xpath("//symbol/data").first(MAX_CODES).filter_map do |node|
        data = node["format"] == "base64" ? Base64.decode64(node.text) : node.text
        data.dup.force_encoding(Encoding::UTF_8).scrub.presence
      end
    end
end
