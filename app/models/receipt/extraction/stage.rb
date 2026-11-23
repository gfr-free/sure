# frozen_string_literal: true

# One way of reading a receipt, run by Receipt::Extraction. A stage is a
# subclass in Receipt::Extraction::Stages that sets `position` (lower runs
# first; e-invoices before codes before text before recognition before AI) and
# `source` (the key of its label under receipts.sources), and implements #read.
#
# #read returns a Reading, or nil when it found nothing. It raises
# Receipt::Extraction::Error for a file it cannot read; an optional tool that is
# missing on this server is reported with `extraction.notice!` instead.
class Receipt::Extraction::Stage
  # `fields` maps a field to { value:, confidence: }. `text` is added to the
  # receipt's raw text. `attributes` sets further receipt columns. `settles`
  # names fields no later stage may fill (an e-invoice without an amount has
  # none, whatever its printed copy shows).
  Reading = Data.define(:fields, :text, :attributes, :settles) do
    def initialize(fields: {}, text: nil, attributes: {}, settles: [])
      super
    end
  end

  class << self
    def position
      raise NotImplementedError, "#{name} must define .position"
    end

    def source
      raise NotImplementedError, "#{name} must define .source"
    end

    # Receipt columns this stage writes, with the value they get when the stage
    # does not run, so a new read never keeps a stale value.
    def default_attributes
      {}
    end
  end

  attr_reader :extraction

  delegate :receipt, :fields, to: :extraction

  def initialize(extraction)
    @extraction = extraction
  end

  def source
    self.class.source
  end

  # Whether the stage can read this kind of file at all.
  def applicable?
    true
  end

  # Whether running is worth it, given what the earlier stages read.
  def wanted?
    applicable? && extraction.missing_fields.any?
  end

  # Whether this stage's value replaces the one an earlier stage read.
  def replaces?(_field, _earlier)
    false
  end

  def read
    raise NotImplementedError, "#{self.class.name} must define #read"
  end

  private
    # The fields Receipt::TextParser finds in `text`, with the text itself.
    def text_reading(text)
      return nil if text.blank?

      fields = Receipt::TextParser.parse(text, currency_hint: receipt.family.currency, merchant_names: extraction.merchant_names)
      Reading.new(fields: fields, text: text)
    end
end
