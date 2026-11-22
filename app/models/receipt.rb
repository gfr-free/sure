# frozen_string_literal: true

require "digest/sha2"

# A receipt or invoice in the receipt inbox. Sure reads its header data (merchant,
# date, amount, currency) in the background; the person who uploaded it then links
# it to a transaction or turns it into a new one. Linking copies the file onto the
# transaction's attachments, so deleting the receipt later never touches the
# transaction's copy.
#
# Receipts are private to their uploader until linked: the inbox, the file and the
# read text are only shown to the user who added them.
class Receipt < ApplicationRecord
  include Encryptable

  DuplicateUploadError = Class.new(StandardError) do
    attr_reader :receipt

    def initialize(receipt)
      @receipt = receipt
      super("Receipt file has already been uploaded")
    end
  end
  InvalidUploadError = Class.new(StandardError)

  MAX_FILE_SIZE = Transaction::MAX_ATTACHMENT_SIZE
  ALLOWED_CONTENT_TYPES = Transaction::ALLOWED_CONTENT_TYPES
  # The manual search reaches further than an automatic match would, like the
  # transfer dialog: the user confirms the pick themselves.
  CANDIDATE_DATE_WINDOW = 30
  MAX_CANDIDATES = 20
  FIELDS = %w[merchant_name date amount currency].freeze

  if encryption_ready?
    encrypts :raw_text
  end

  belongs_to :family
  belongs_to :uploaded_by, class_name: "User", optional: true
  # Not `transaction`: that name is ActiveRecord's own transaction method.
  belongs_to :linked_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true, inverse_of: :receipts

  has_one_attached :file, dependent: :purge_later

  enum :source, { web: "web", email: "email" }, validate: true, default: "web"
  enum :extraction_status, { pending: "pending", completed: "completed", failed: "failed" }, validate: true, default: "pending", prefix: :extraction

  validates :filename, :content_type, :byte_size, :content_sha256, presence: true
  validates :content_type, inclusion: { in: ALLOWED_CONTENT_TYPES }
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE }
  validates :amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :merchant_name, length: { maximum: 200 }
  validate :currency_is_valid
  validate :linked_transaction_belongs_to_family

  before_validation :normalize_fields

  after_create_commit :extract_later

  scope :ordered, -> { order(created_at: :desc) }
  scope :open, -> { where(transaction_id: nil, dismissed_at: nil) }
  scope :done, -> { where.not(transaction_id: nil).or(where.not(dismissed_at: nil)) }
  scope :uploaded_by, ->(user) { where(uploaded_by: user) }

  class << self
    def manager?(user)
      user&.admin? || user&.member?
    end

    def create_from_upload!(family:, user:, file:)
      create_from_content!(family: family, user: user, content: read_upload!(file), filename: file.original_filename.to_s, source: "web")
    end

    def create_from_content!(family:, user:, content:, filename:, source:)
      raise InvalidUploadError if content.empty? || content.bytesize > MAX_FILE_SIZE

      content_type = Marcel::MimeType.for(StringIO.new(content), name: filename)
      raise InvalidUploadError unless ALLOWED_CONTENT_TYPES.include?(content_type)

      content_sha256 = Digest::SHA256.hexdigest(content)
      duplicate = family.receipts.find_by(uploaded_by: user, content_sha256: content_sha256)
      raise DuplicateUploadError, duplicate if duplicate

      receipt = family.receipts.build(
        uploaded_by: user,
        source: source,
        filename: upload_filename(filename),
        content_type: content_type,
        byte_size: content.bytesize,
        content_sha256: content_sha256,
        currency: family.currency
      )
      receipt.file.attach(io: StringIO.new(content), filename: receipt.filename, content_type: content_type)
      receipt.save!
      receipt
    rescue ActiveRecord::RecordNotUnique
      duplicate = family.receipts.find_by(uploaded_by: user, content_sha256: content_sha256)
      raise DuplicateUploadError, duplicate if duplicate

      raise
    end

    private
      # Fits the 255-character column, keeping the extension.
      def upload_filename(original)
        name = ActiveStorage::Filename.new(original.to_s.presence || "receipt").sanitized
        return name if name.length <= 255

        extension = File.extname(name).first(20)
        "#{File.basename(name, File.extname(name)).first(255 - extension.length)}#{extension}"
      end

      def read_upload!(file)
        raise InvalidUploadError unless file.respond_to?(:read)
        raise InvalidUploadError if file.respond_to?(:size) && file.size.to_i > MAX_FILE_SIZE

        content = file.read(MAX_FILE_SIZE + 1).to_s
        raise InvalidUploadError if content.empty? || content.bytesize > MAX_FILE_SIZE

        content
      end
  end

  def status
    return :dismissed if dismissed_at?
    return :linked if transaction_id?
    return :reading if extraction_pending?

    :open
  end

  def image?
    content_type.start_with?("image/")
  end

  def pdf?
    content_type == "application/pdf"
  end

  def amount_money
    return nil if amount.nil? || currency.blank?

    Money.new(amount, currency)
  end

  def field_source(field)
    field_sources.dig(field.to_s, "source")
  end

  def field_confidence(field)
    field_sources.dig(field.to_s, "confidence")
  end

  def extract_later
    ReceiptExtractionJob.perform_later(self)
  end

  # Reads the header data from the file. Fields the user has already edited by
  # hand keep their value.
  def extract!
    result = Receipt::Extraction.new(self).run

    # Reading can take a while; the lock reloads the row, so an edit saved
    # meanwhile counts as manual and is kept.
    with_lock do
      manual = FIELDS.select { |field| field_source(field) == "manual" }
      attrs = { raw_text: result.raw_text, extraction_status: "completed", extraction_error: nil }
      sources = field_sources.slice(*manual)
      (FIELDS - manual).each do |field|
        value = result.fields[field]
        next if value.nil?

        attrs[field] = value[:value]
        sources[field] = { "source" => value[:source], "confidence" => value[:confidence] }
      end

      update!(attrs.merge(field_sources: sources))
    end
  rescue Receipt::Extraction::Error => e
    update!(extraction_status: "failed", extraction_error: e.code)
  rescue StandardError => e
    # The receipt stays usable: the user enters the details by hand. The message
    # names the error class only, never text read from the receipt.
    DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{id}: extraction failed: #{e.class}",
                          source: "receipt_extraction", family: family, user_id: uploaded_by_id)
    update!(extraction_status: "failed", extraction_error: "unexpected_error")
  end

  # Applies the user's own corrections and marks each changed field as manual.
  def update_fields!(attrs)
    attrs = attrs.to_h.stringify_keys.slice(*FIELDS)
    assign_attributes(attrs)
    normalize_fields
    sources = field_sources.dup
    FIELDS.each do |field|
      sources[field] = { "source" => "manual", "confidence" => 1.0 } if will_save_change_to_attribute?(field)
    end
    self.field_sources = sources
    save!
  end

  # Transactions on accounts the user may write to, near the receipt's date and,
  # when the amount is known, for exactly that amount. Without a date, the most
  # recent ones with the amount.
  def match_candidates(user)
    scope = linkable_transactions(user).where(entries: { excluded: false }).includes(entry: :account)

    scope = scope.where(entries: { amount: amount, currency: currency }) if amount.present? && currency.present?

    if date.present?
      scope = scope.where(entries: { date: (date - CANDIDATE_DATE_WINDOW)..(date + CANDIDATE_DATE_WINDOW) })
                   .order(Arel.sql(ActiveRecord::Base.sanitize_sql_array([ "ABS(entries.date - ?::date)", date ])))
    else
      return Transaction.none if amount.blank?

      scope = scope.order("entries.date DESC")
    end

    scope.limit(MAX_CANDIDATES)
  end

  # Every transaction the user may attach this receipt to.
  def linkable_transactions(user)
    Transaction.joins(:entry).where(entries: { account_id: family.accounts.writable_by(user).select(:id) })
  end

  def link_to!(transaction, user:)
    raise ActiveRecord::RecordNotFound unless writable_account?(transaction.entry.account, user)

    with_lock { attach_to!(transaction, created: false) }
  end

  # Records the receipt as a new expense on `account`, then links it.
  def create_transaction!(account:, user:, name:, date:, amount:, currency:)
    raise ActiveRecord::RecordNotFound unless writable_account?(account, user)
    refuse!(:invalid_transaction) unless amount.is_a?(Numeric) && amount.positive? && date.is_a?(Date) && known_currency?(currency)

    entry = nil
    with_lock do
      refuse!(:already_linked) if transaction_id?

      entry = account.entries.create!(
        name: name,
        date: date,
        amount: amount,
        currency: currency,
        entryable: Transaction.new(merchant: merchant_for(name))
      )
      attach_to!(entry.transaction, created: true)
    end

    entry.sync_account_later
    entry.lock_saved_attributes!
    entry.mark_user_modified!
    entry.apply_immediate_rules_later
    entry
  end

  def dismiss!
    update!(dismissed_at: Time.current)
  end

  def reopen!
    update!(dismissed_at: nil)
  end

  private
    # Runs inside the receipt's row lock, so two clicks cannot link it twice.
    def attach_to!(transaction, created:)
      refuse!(:already_linked) if transaction_id?

      transaction.with_lock do
        if transaction.attachments.count >= Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
          refuse!(:too_many_attachments, max: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION)
        end

        transaction.attachments.attach(io: StringIO.new(file.download), filename: filename, content_type: content_type)
        update!(linked_transaction: transaction, linked_at: Time.current, dismissed_at: nil, created_transaction: created)
      end
    end

    def refuse!(error, **options)
      errors.add(:base, error, **options)
      raise ActiveRecord::RecordInvalid, self
    end

    def normalize_fields
      self.merchant_name = merchant_name.to_s.squish.presence&.truncate(200, omission: "")
      self.currency = currency.to_s.strip.upcase.presence
    end

    def currency_is_valid
      errors.add(:currency, :invalid) if currency.present? && !known_currency?(currency)
    end

    def known_currency?(code)
      Money::Currency.new(code.to_s)
      true
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    def linked_transaction_belongs_to_family
      return if linked_transaction.nil?
      return if linked_transaction.entry&.account&.family_id == family_id

      errors.add(:linked_transaction, :invalid)
    end

    def writable_account?(account, user)
      account.family_id == family_id && family.accounts.writable_by(user).where(id: account.id).exists?
    end

    def merchant_for(name)
      return nil if merchant_name.blank? && name.blank?

      family.merchants.where("LOWER(name) = ?", (merchant_name.presence || name).downcase).first
    end
end
