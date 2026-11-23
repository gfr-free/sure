# The files embedded in a PDF: those in the document's EmbeddedFiles name tree
# and the PDF/A-3 associated files (/AF), where ZUGFeRD and Factur-X keep their
# invoice XML.
#
# `list` only collects names; a file's content is inflated when it is read.
# Only uncompressed and Flate-compressed streams are read, and inflating stops
# at max_size bytes, so a small PDF cannot expand into gigabytes. The name tree
# walk is bounded too, so a tree that repeats or refers back to its own nodes
# ends quickly. A PDF the reader cannot open yields what was found up to then.
module Pdf::EmbeddedFiles
  MAX_FILES = 20
  MAX_TREE_NODES = 100
  UTF16_BOM = "\xFE\xFF".b.freeze

  TooLarge = Class.new(StandardError)

  EmbeddedFile = Data.define(:name, :stream) do
    def read(max_size:)
      Pdf::EmbeddedFiles.stream_content(stream, max_size)
    end
  end

  class << self
    def list(content)
      files = []
      objects = PDF::Reader.new(StringIO.new(content.to_s)).objects
      catalog = objects.deref_hash(objects.trailer[:Root]) || {}
      stream_refs = Set.new

      file_specs(objects, catalog).each do |spec_ref|
        spec = objects.deref_hash(spec_ref)
        streams = objects.deref_hash(spec&.dig(:EF))
        stream_ref = streams && (streams[:UF] || streams[:F])
        next if stream_ref.nil? || !stream_refs.add?(stream_ref)

        stream = objects.deref_stream(stream_ref)
        files << EmbeddedFile.new(name: decode_name(objects.deref(spec[:UF] || spec[:F])), stream: stream) if stream
      end
      files
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      files || []
    end

    def stream_content(stream, max_size)
      filters = Array(stream.hash[:Filter])
      return if filters.size > 1 || stream.hash[:DecodeParms].present?

      data = stream.data.to_s
      case filters.first
      when nil
        data if data.bytesize <= max_size
      when :FlateDecode
        inflate(data, max_size)
      end
    end

    private
      def file_specs(objects, catalog)
        specs = []
        names = objects.deref_hash(catalog[:Names])
        collect_name_tree(objects, names[:EmbeddedFiles], specs) if names
        specs.concat(Array(objects.deref_array(catalog[:AF])))
        specs.uniq.first(MAX_FILES)
      end

      # Name tree nodes hold [name, value, ...] pairs in /Names and child nodes
      # in /Kids. Each node is visited once, and at most MAX_TREE_NODES of them.
      def collect_name_tree(objects, root_ref, specs)
        queue = [ root_ref ]
        visited = Set.new

        while (node_ref = queue.shift) && visited.size < MAX_TREE_NODES && specs.size < MAX_FILES
          next unless visited.add?(node_ref)

          node = objects.deref_hash(node_ref)
          next if node.nil?

          Array(objects.deref_array(node[:Names])).each_slice(2) { |_name, spec| specs << spec }
          queue.concat(Array(objects.deref_array(node[:Kids])))
        end
      end

      def inflate(data, max_size)
        inflater = Zlib::Inflate.new
        output = +"".b
        inflater.inflate(data) do |chunk|
          output << chunk
          raise TooLarge if output.bytesize > max_size
        end
        output
      rescue TooLarge, Zlib::Error
        nil
      ensure
        inflater&.close
      end

      def decode_name(name)
        name = name.to_s.b
        if name.start_with?(UTF16_BOM)
          name.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        else
          name.force_encoding(Encoding::UTF_8).scrub
        end
      end
  end
end
