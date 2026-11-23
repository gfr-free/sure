# frozen_string_literal: true

require "open3"

# Reads the text of a photo or a scanned PDF with Tesseract, without AI.
#
# Photos are prepared with libvips first (EXIF rotation, grayscale, contrast,
# a size Tesseract reads well). Scanned PDFs are rendered page by page with
# pdftoppm. Both programs run with a time limit, on a temporary copy, and with
# an empty environment, so no API key or secret ever reaches them.
#
# Tesseract is optional: without it, or without a usable language pack,
# `available?` is false and receipts are read from their PDF text only.
class Receipt::Ocr
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  Result = Data.define(:text, :confidence)

  # German and English are installed in the official image; a language from the
  # user's locale is added when its pack happens to be installed too.
  DEFAULT_LANGUAGES = %w[deu eng].freeze
  LOCALE_LANGUAGES = {
    "ca" => "cat", "de" => "deu", "en" => "eng", "es" => "spa", "fr" => "fra", "id" => "ind", "it" => "ita",
    "nl" => "nld", "pl" => "pol", "pt" => "por", "ru" => "rus", "tr" => "tur", "uk" => "ukr", "zh-CN" => "chi_sim"
  }.freeze

  # Each upload is decoded only by the loader for its declared type, so a file
  # declared as PNG never reaches the SVG, PDF or other loaders libvips has.
  IMAGE_LOADERS = {
    "image/jpeg" => :jpegload_buffer, "image/png" => :pngload_buffer,
    "image/webp" => :webpload_buffer, "image/gif" => :gifload_buffer
  }.freeze

  # Guards against decompression bombs: a 10 MB upload can still declare a huge
  # canvas, and libvips only reads the header until pixels are needed.
  MAX_PIXELS = 50_000_000
  # Tesseract reads best at roughly 300 dpi; a receipt photo is about this size.
  MIN_LONG_SIDE = 1600
  MAX_LONG_SIDE = 4000
  # Renders a scanned A4 page at roughly 300 dpi, whatever the page box says.
  PDF_RENDER_LONG_SIDE = 3500
  COMMAND_TIMEOUT = 30
  # Pages of a long scan after this many seconds are left unread, so one file
  # cannot hold a worker for minutes.
  PDF_TIME_BUDGET = 90
  # Single column of text lines: keeps "SUMME ... 12,30" on one line, where the
  # automatic layout often splits a receipt's label and amount into two blocks.
  PAGE_SEGMENTATION_MODE = "4"
  # What the programs report is cached per process; a failed probe is retried
  # sooner than a successful one.
  PROBE_TTL = 1.hour
  FAILED_PROBE_TTL = 1.minute

  class << self
    def available?(locale: nil)
      languages(locale: locale).any?
    end

    # Scanned PDFs also need pdftoppm (poppler-utils).
    def pdf_available?(locale: nil)
      available?(locale: locale) && pdf_renderer_installed?
    end

    # The installed language packs to read with, e.g. ["deu", "eng", "fra"] for
    # a French locale when the French pack is installed.
    def languages(locale: nil)
      wanted = DEFAULT_LANGUAGES + [ LOCALE_LANGUAGES[locale.to_s] ].compact
      installed_languages & wanted.uniq
    end

    def installed_languages
      probe(:languages) do
        stdout, _stderr, status = run("tesseract", "--list-langs", timeout: 10)
        status.success? ? stdout.lines.drop(1).map(&:strip).reject(&:blank?) : nil
      end || []
    end

    def pdf_renderer_installed?
      probe(:pdf_renderer) do
        _stdout, _stderr, status = run("pdftoppm", "-v", timeout: 10)
        status.success? || nil
      end || false
    end

    def reset_cache!
      @probes = {}
    end

    # Runs a program without the app's environment and kills it, with any
    # child processes, once the time is up.
    def run(*command, timeout: COMMAND_TIMEOUT)
      env = { "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"), "OMP_THREAD_LIMIT" => "1" }
      env["TESSDATA_PREFIX"] = ENV["TESSDATA_PREFIX"] if ENV["TESSDATA_PREFIX"].present?

      Open3.popen3(env, *command, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, wait|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        unless wait.join(timeout)
          begin
            Process.kill("KILL", -wait.pid)
          rescue Errno::ESRCH
            nil
          end
          wait.join
          # The readers see end of file once the process group is gone.
          [ out, err ].each { _1.join(5) }
          raise Error, "ocr_timeout"
        end
        [ out.value.to_s, err.value.to_s, wait.value ]
      end
    rescue Errno::ENOENT
      raise Error, "ocr_unavailable"
    end

    private
      # The block returns nil when the probe failed.
      def probe(key)
        @probes ||= {}
        cached = @probes[key]
        return cached[:value] if cached && cached[:expires_at] > Time.current

        value = begin
          yield
        rescue Error
          nil
        end
        @probes[key] = { value: value, expires_at: Time.current + (value.nil? ? FAILED_PROBE_TTL : PROBE_TTL) }
        value
      end
  end

  def initialize(locale: nil)
    @languages = self.class.languages(locale: locale)
  end

  def read_image(content, content_type:)
    loader = IMAGE_LOADERS[content_type]
    raise Error, "unreadable_image" unless loader

    Dir.mktmpdir("receipt-ocr") do |dir|
      path = File.join(dir, "page.png")
      prepare_image(Vips::Image.public_send(loader, content), path)
      result_for([ recognize(path) ])
    end
  rescue Vips::Error
    raise Error, "unreadable_image"
  end

  def read_pdf(content, max_pages:)
    deadline = monotonic_now + PDF_TIME_BUDGET

    Dir.mktmpdir("receipt-ocr") do |dir|
      pdf_path = File.join(dir, "receipt.pdf")
      File.binwrite(pdf_path, content)
      _stdout, _stderr, status = self.class.run(
        "pdftoppm", "-png", "-gray", "-scale-to", PDF_RENDER_LONG_SIDE.to_s, "-f", "1", "-l", max_pages.to_s,
        pdf_path, File.join(dir, "page")
      )
      raise Error, "unreadable_pdf" unless status.success?

      pages = Dir.glob(File.join(dir, "page*.png")).sort
      raise Error, "unreadable_pdf" if pages.empty?

      read = []
      pages.each do |page|
        break if read.any? && monotonic_now > deadline

        prepared = "#{page}.ocr.png"
        prepare_image(Vips::Image.pngload(page), prepared)
        # Later pages only get the time left in the budget; the first page is
        # always read in full so a slow scan still yields something.
        timeout = read.empty? ? COMMAND_TIMEOUT : (deadline - monotonic_now).clamp(0, COMMAND_TIMEOUT)
        break if timeout <= 0

        begin
          read << recognize(prepared, timeout: timeout)
        rescue Error => e
          raise if read.empty? || e.code != "ocr_timeout"

          break
        end
      end
      result_for(read)
    end
  rescue Vips::Error
    raise Error, "unreadable_pdf"
  end

  private
    attr_reader :languages

    def prepare_image(image, path)
      raise Error, "image_too_large" if image.width.to_i * image.height.to_i > MAX_PIXELS

      image = image.autorot
      # White is 65535 in a 16-bit image, not 255.
      image = image.flatten(background: [ white_point(image) ] * (image.bands - 1)) if image.has_alpha?
      # Also scales a 16-bit PNG down to 8 bits.
      image = image.colourspace(:b_w)
      image = image.extract_band(0) if image.bands > 1
      image = stretch_contrast(image)
      image = resize(image)
      image.cast(:uchar).pngsave(path)
    end

    def white_point(image)
      %i[grey16 rgb16].include?(image.interpretation) ? 65_535 : 255
    end

    # Spreads the darkest and brightest percent over the full range, which lifts
    # faded thermal paper and photos taken in poor light.
    def stretch_contrast(image)
      low = image.percent(1)
      high = image.percent(99)
      return image if high - low < 16 || (low.zero? && high >= 255)

      ((image - low) * (255.0 / (high - low))).cast(:uchar)
    end

    def resize(image)
      long_side = [ image.width, image.height ].max
      scale = if long_side < MIN_LONG_SIDE
        [ MIN_LONG_SIDE.to_f / long_side, 3.0 ].min
      elsif long_side > MAX_LONG_SIDE
        MAX_LONG_SIDE.to_f / long_side
      end
      scale ? image.resize(scale) : image
    end

    def recognize(path, timeout: COMMAND_TIMEOUT)
      raise Error, "ocr_unavailable" if languages.empty?

      stdout, _stderr, status = self.class.run(
        "tesseract", path, "stdout", "-l", languages.join("+"), "--psm", PAGE_SEGMENTATION_MODE, "tsv", timeout: timeout
      )
      raise Error, "ocr_failed" unless status.success?

      parse_tsv(stdout)
    end

    # Tesseract's TSV has one row per word with its block, paragraph and line;
    # words of one line are joined back with single spaces.
    def parse_tsv(tsv)
      lines = {}
      confidences = []
      tsv.each_line.drop(1).each do |row|
        cols = row.chomp.split("\t", 12)
        next unless cols.length == 12 && cols[0] == "5"

        word = cols[11].to_s.strip
        next if word.empty?

        confidence = cols[10].to_f
        confidences << confidence if confidence >= 0
        (lines[cols[1..4]] ||= []) << word
      end

      { text: lines.values.map { _1.join(" ") }.join("\n"), confidences: confidences }
    end

    def result_for(pages)
      confidences = pages.flat_map { _1[:confidences] }
      text = Receipt::Ocr::TextCleanup.call(pages.map { _1[:text] }.join("\n"))
      confidence = confidences.any? ? (confidences.sum / confidences.size / 100.0).round(2) : 0.0
      Result.new(text: text, confidence: confidence)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
