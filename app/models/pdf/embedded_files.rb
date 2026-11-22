# The files embedded in a PDF, as { filename => content }: those in the
# document's EmbeddedFiles name tree and the PDF/A-3 associated files (/AF),
# where ZUGFeRD and Factur-X keep their invoice XML.
#
# Only uncompressed and Flate-compressed streams are read, and inflating stops
# at max_size bytes, so a small PDF cannot expand into gigabytes. A PDF the
# reader cannot open yields what was read up to that point.
module Pdf::EmbeddedFiles
  MAX_FILES = 20
  MAX_TREE_DEPTH = 10
  UTF16_BOM = "\xFE\xFF".b.freeze

  TooLarge = Class.new(StandardError)

  class << self
    def read(content, max_size:)
      files = {}
      objects = PDF::Reader.new(StringIO.new(content.to_s)).objects
      catalog = objects.deref_hash(objects.trailer[:Root]) || {}

      file_specs(objects, catalog).each do |spec|
        name, data = read_file_spec(objects, spec, max_size)
        files[name] ||= data if name.present? && data
      end
      files
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      files || {}
    end

    private
      def file_specs(objects, catalog)
        specs = []
        names = objects.deref_hash(catalog[:Names])
        collect_name_tree(objects, names[:EmbeddedFiles], specs, 0) if names
        specs.concat(Array(objects.deref_array(catalog[:AF])))
        specs.uniq.first(MAX_FILES)
      end

      # Name tree nodes hold [name, value, ...] pairs in /Names and child nodes
      # in /Kids. The depth limit also stops a tree that refers back to itself.
      def collect_name_tree(objects, node_ref, specs, depth)
        return if depth > MAX_TREE_DEPTH || specs.size >= MAX_FILES

        node = objects.deref_hash(node_ref)
        return if node.nil?

        Array(objects.deref_array(node[:Names])).each_slice(2) { |_name, spec| specs << spec }
        Array(objects.deref_array(node[:Kids])).each { |kid| collect_name_tree(objects, kid, specs, depth + 1) }
      end

      def read_file_spec(objects, spec_ref, max_size)
        spec = objects.deref_hash(spec_ref)
        return if spec.nil?

        streams = objects.deref_hash(spec[:EF])
        return if streams.nil?

        stream = objects.deref_stream(streams[:UF] || streams[:F])
        return if stream.nil?

        [ decode_name(objects.deref(spec[:UF] || spec[:F])), stream_content(stream, max_size) ]
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
