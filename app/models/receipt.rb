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
#
# Like transfers, Sure also links a receipt on its own when exactly one
# transaction fits it. Such a link stays a suggestion (match_status "pending")
# until the uploader confirms it; only then is the file copied onto the
# transaction. A rejected pair is remembered and never suggested again.
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
  # Banks book card payments a few days after the purchase, rarely a day before.
  AUTO_MATCH_DAYS_BEFORE = 1
  AUTO_MATCH_DAYS_AFTER = 5
  BANK_WAIT_DAY_OPTIONS = [ 0, 3, 5, 7, 10, 14, 21, 30 ].freeze
  # Fits numeric(19,4), the type of receipts.amount and entries.amount.
  MAX_AMOUNT = 10**15

  if encryption_ready?
    encrypts :raw_text
  end

  belongs_to :family
  belongs_to :uploaded_by, class_name: "User", optional: true, inverse_of: :uploaded_receipts
  # Not `transaction`: that name is ActiveRecord's own transaction method.
  belongs_to :linked_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true, inverse_of: :receipts

  has_many :rejected_matches, class_name: "RejectedReceiptMatch", dependent: :destroy

  has_one_attached :file, dependent: :purge_later

  # How a receipt arrived: the web upload, the API or an e-mail to the uploader's
  # receipt address.
  enum :source, { web: "web", api: "api", email: "email" }, validate: true, default: "web"
  enum :extraction_status, { pending: "pending", completed: "completed", failed: "failed" }, validate: true, default: "pending", prefix: :extraction
  # Only meaningful while transaction_id is set: deleting the transaction clears
  # the link in the database and leaves this value behind.
  enum :match_status, { pending: "pending", confirmed: "confirmed" }, validate: { allow_nil: true }, prefix: :match

  validates :filename, :content_type, :byte_size, :content_sha256, presence: true
  validates :content_type, inclusion: { in: ALLOWED_CONTENT_TYPES }
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE }
  validates :amount, numericality: { greater_than: 0, less_than: MAX_AMOUNT }, allow_nil: true
  validates :merchant_name, length: { maximum: 200 }
  validate :currency_is_valid
  validate :linked_transaction_belongs_to_family

  before_validation :normalize_fields

  # Set by a caller that reads the receipt right away itself.
  attr_accessor :skip_extract_later

  after_create_commit :extract_later, unless: :skip_extract_later

  scope :ordered, -> { order(created_at: :desc) }
  scope :open, -> { where(transaction_id: nil, dismissed_at: nil) }
  scope :suggested, -> { where.not(transaction_id: nil).where(match_status: "pending", dismissed_at: nil) }
  # Receipts the user linked to a transaction themselves or whose suggestion
  # they confirmed; a pending suggestion does not count.
  scope :linked, -> { where.not(transaction_id: nil).where(match_status: "confirmed") }
  scope :done, -> { linked.or(where.not(dismissed_at: nil)) }
  scope :uploaded_by, ->(user) { where(uploaded_by: user) }

  class << self
    def manager?(user)
      user&.admin? || user&.member?
    end

    def create_from_upload!(family:, user:, file:, source: "web", extract_later: true)
      create_from_content!(family: family, user: user, content: read_upload!(file), filename: file.original_filename.to_s,
                           source: source, extract_later: extract_later)
    end

    # Every way in (web, API, e-mail) ends here. `extract_later: false` leaves
    # the reading to the caller, which reads the receipt right away.
    def create_from_content!(family:, user:, content:, filename:, source: "web", extract_later: true)
      raise InvalidUploadError if content.empty? || content.bytesize > MAX_FILE_SIZE

      # Decided from the bytes alone: with a name hint, Marcel falls back to the
      # extension, so any file named ".pdf" would pass.
      content_type = Marcel::MimeType.for(StringIO.new(content))
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
      receipt.skip_extract_later = !extract_later
      blob = upload_blob!(content, filename: receipt.filename, content_type: content_type)
      begin
        receipt.file.attach(blob)
        receipt.save!
      rescue StandardError => e
        # A rolled-back save leaves the receipt unsaved. Once it is committed, a
        # failure in an after-commit callback must not report the upload as
        # failed or remove the file of a stored receipt.
        if receipt.persisted?
          DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{receipt.id}: after-commit step failed: #{e.class}",
                                source: "receipt_upload", family: family, user_id: user.id)
          return receipt
        end

        discard_blob(blob)
        raise
      end
      receipt
    rescue ActiveRecord::RecordNotUnique
      duplicate = family.receipts.find_by(uploaded_by: user, content_sha256: content_sha256)
      raise DuplicateUploadError, duplicate if duplicate

      raise
    end

    # Suggests a transaction for each open receipt of the family. Runs after a
    # sync. Every writable account is searched, so a receipt is only suggested
    # when its match is unique across them.
    def auto_match_open(family)
      family.receipts.open.where.not(extraction_status: "pending")
            .where.not(uploaded_by_id: nil).where.not(amount: nil).where.not(date: nil)
            .find_each do |receipt|
        receipt.auto_match!
      rescue StandardError => e
        DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{receipt.id}: auto match failed: #{e.class}",
                              source: "receipt_auto_match", family: family, user_id: receipt.uploaded_by_id)
      end
    end

    # Drops pending suggestions on `account` whose uploader may no longer write
    # to it, so the receipt is back in the inbox instead of stuck on a
    # suggestion they can neither see nor confirm.
    def release_unwritable_suggestions(account)
      pending = where(family_id: account.family_id, match_status: "pending")
                  .where(transaction_id: Transaction.joins(:entry).where(entries: { account_id: account.id }).select(:id))
      pending.where.not(uploaded_by_id: nil).includes(:uploaded_by).find_each do |receipt|
        next if receipt.uploaded_by && Account.writable_by(receipt.uploaded_by).exists?(id: account.id)

        receipt.with_lock do
          receipt.update!(linked_transaction: nil, match_status: nil, linked_at: nil) if receipt.match_pending?
        end
      end
    end

    # Uploads the file before the blob row is saved, so a storage error leaves
    # neither a row nor a receipt behind. Active Storage would otherwise upload
    # after the commit, and a failure there would keep a receipt without a file
    # whose checksum blocks the next try as a duplicate.
    def upload_blob!(content, filename:, content_type:)
      blob = ActiveStorage::Blob.build_after_unfurling(io: StringIO.new(content), filename: filename, content_type: content_type, identify: false)
      begin
        blob.upload_without_unfurling(StringIO.new(content))
        blob.save!
      rescue StandardError
        # A failed write can leave a partial file at the key; removing it must
        # not hide the original error.
        begin
          blob.delete
        rescue StandardError
          nil
        end
        raise
      end
      blob
    end

    # Removes a blob that will not be used, without letting a storage error
    # replace the error that caused the removal.
    def discard_blob(blob)
      blob&.purge
    rescue StandardError => e
      Rails.logger.warn("Receipt: could not remove unused blob #{blob&.key}: #{e.class}")
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
    return :suggested if suggested?
    return :linked if transaction_id?
    return :reading if extraction_pending?

    :open
  end

  def suggested?
    transaction_id? && match_pending? && !dismissed_at?
  end

  # Until this day an open receipt is not turned into a new transaction on a
  # bank-synced account: the bank's own booking usually arrives a few days after
  # the purchase and would otherwise be a duplicate.
  def bank_wait_until
    (date || created_at.to_date) + family.receipt_bank_wait_days
  end

  # A dismissed receipt waits too: recording it reopens it as a new transaction.
  def awaiting_bank?(today = Date.current)
    family.receipt_bank_wait_days.positive? && !transaction_id? && today < bank_wait_until
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

  # Whether reading the file filled anything, as opposed to the user typing it.
  def fields_read?
    raw_text.present? || field_sources.values.any? { |info| info["source"].present? && info["source"] != "manual" }
  end

  def field_confidence(field)
    field_sources.dig(field.to_s, "confidence")
  end

  # Runs after the commit, so an unreachable queue cannot undo the upload. The
  # receipt is then marked failed instead of reading forever, and stays usable
  # by hand.
  def extract_later
    job = ReceiptExtractionJob.perform_later(self)
    enqueue_failed!("not enqueued") unless job&.successfully_enqueued?
  rescue StandardError => e
    enqueue_failed!(e.class)
  end

  # Reads the header data from the file. Fields the user has already edited by
  # hand keep their value.
  def extract!
    result = Receipt::Extraction.new(self).run

    # Reading can take a while; the lock reloads the row, so an edit saved
    # meanwhile counts as manual and is kept.
    with_lock do
      manual = FIELDS.select { |field| field_source(field) == "manual" }
      # On a completed read the error column keeps the notice, so the page can
      # say why fields are blank.
      attrs = { raw_text: result.raw_text, extraction_status: "completed", extraction_error: result.notice }.merge(result.attributes)
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
    reload.update!(extraction_status: "failed", extraction_error: e.code)
  rescue StandardError => e
    # The receipt stays usable: the user enters the details by hand. The message
    # names the error class only, never text read from the receipt. The reload
    # drops whatever read value made the save fail, so this save does not too.
    DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{id}: extraction failed: #{e.class}",
                          source: "receipt_extraction", family: family, user_id: uploaded_by_id)
    reload.update!(extraction_status: "failed", extraction_error: "unexpected_error")
  end

  # Applies the user's own corrections and marks each changed field as manual.
  # Locked like the merge in extract!, so a read finishing at the same time
  # cannot drop the manual marks.
  # `rendered` holds the values the form showed. A field submitted unchanged is
  # left alone, so a form opened before reading finished does not blank what
  # was read since; clearing a field on purpose still counts as a change.
  def update_fields!(attrs, rendered = {})
    rendered = rendered.to_h.stringify_keys
    attrs = attrs.to_h.stringify_keys.slice(*FIELDS).reject { |field, value| rendered.key?(field) && rendered[field].to_s == value.to_s }
    with_lock do
      assign_attributes(attrs)
      normalize_fields
      sources = field_sources.dup
      FIELDS.each do |field|
        sources[field] = { "source" => "manual", "confidence" => 1.0 } if will_save_change_to_attribute?(field)
      end
      self.field_sources = sources
      # A suggestion was made for the old amount, currency or date.
      if suggested? && %w[amount currency date].any? { |field| will_save_change_to_attribute?(field) }
        assign_attributes(linked_transaction: nil, match_status: nil, linked_at: nil)
      end
      save!
    end
  end

  # Transactions on accounts the user may write to, near the receipt's date and,
  # when the amount is known, for exactly that amount. Without a date, the most
  # recent ones with the amount.
  def match_candidates(user)
    scope = linkable_transactions(user).where(entries: { excluded: false }).includes(entry: :account)

    scope = scope.where(entries: { amount: amount }) if amount.present?
    scope = scope.where(entries: { currency: currency }) if amount.present? && currency.present?

    if date.present?
      scope = scope.where(entries: { date: (date - CANDIDATE_DATE_WINDOW)..(date + CANDIDATE_DATE_WINDOW) })
                   .order(Arel.sql(ActiveRecord::Base.sanitize_sql_array([ "ABS(entries.date - ?::date)", date ])))
    else
      return Transaction.none if amount.blank?

      scope = scope.order("entries.date DESC")
    end

    scope.limit(MAX_CANDIDATES)
  end

  # The transactions an automatic match may pick: exactly the receipt's amount as
  # an expense in its currency, booked from a day before to a few days after the
  # receipt's date, on an account the uploader may write to. Transfers, excluded
  # entries, transactions that already have a receipt and pairs the uploader
  # rejected are left out.
  def auto_match_candidates
    return Transaction.none if uploaded_by.nil? || amount.blank? || date.blank? || currency.blank?

    linkable_transactions(uploaded_by)
      .where(entries: { excluded: false, amount: amount, currency: currency,
                        date: (date - AUTO_MATCH_DAYS_BEFORE)..(date + AUTO_MATCH_DAYS_AFTER) })
      .where.not(kind: Transaction::TRANSFER_KINDS)
      .where.not(id: family.receipts.where.not(transaction_id: nil).select(:transaction_id))
      .where.not(id: rejected_matches.select(:transaction_id))
  end

  # Transactions that may already hold this purchase, for the warning in the
  # new-transaction form: the current suggestion first, then other candidates.
  def existing_matches(user, limit: 3)
    matches = auto_match_candidates.includes(entry: :account).limit(limit).to_a
    suggestion = linkable_transactions(user).includes(entry: :account).find_by(id: transaction_id) if suggested?
    [ suggestion, *matches ].compact.first(limit)
  end

  # Links the receipt to the one transaction that fits it, as a suggestion. Two
  # or more fitting transactions are left for the user to pick from. Returns the
  # suggested transaction, or nil.
  def auto_match!
    matched = nil

    with_lock do
      if auto_matchable?
        candidates = auto_match_candidates.limit(2).to_a
        if candidates.one?
          transaction = candidates.first
          # The transaction's lock keeps two receipts from both taking it; the
          # rules are checked again on the locked row, since the transaction may
          # have been edited, excluded or taken meanwhile.
          transaction.with_lock do
            if auto_match_candidates.exists?(id: transaction.id)
              update!(linked_transaction: transaction, match_status: "pending", linked_at: Time.current, created_transaction: false)
              matched = transaction
            end
          end
        end
      end
    end

    matched
  end

  # `transaction_id` is the suggestion the user saw; a suggestion that changed
  # since is refused instead of confirmed or rejected.
  def confirm_match!(user:, transaction_id: nil)
    with_file_copy do |copy|
      with_lock do
        refuse_changed_suggestion!(transaction_id)
        refuse!(:suggestion_unavailable) unless writable_account?(linked_transaction.entry.account, user)

        attach_to!(linked_transaction, copy, created: false)
      end
    end
  end

  def reject_match!(transaction_id: nil)
    with_lock do
      refuse_changed_suggestion!(transaction_id)

      rejected_matches.find_or_create_by!(transaction_id: self.transaction_id)
      update!(linked_transaction: nil, match_status: nil, linked_at: nil)
    end
  end

  # Every transaction the user may attach this receipt to.
  def linkable_transactions(user)
    Transaction.joins(:entry).where(entries: { account_id: family.accounts.writable_by(user).select(:id) })
  end

  # `created` marks a transaction the user just made from this receipt, e.g. in
  # the new-transaction form.
  def link_to!(transaction, user:, created: false)
    raise ActiveRecord::RecordNotFound unless writable_account?(transaction.entry.account, user)

    with_file_copy do |copy|
      with_lock do
        # Checked again after the copy: the account may have been unshared meanwhile.
        raise ActiveRecord::RecordNotFound unless writable_account?(transaction.entry.account, user)

        attach_to!(transaction, copy, created: created)
      end
    end
  end

  # Records the receipt as a new expense on `account`, then links it.
  def create_transaction!(account:, user:, name:, date:, amount:, currency:)
    raise ActiveRecord::RecordNotFound unless writable_account?(account, user)
    # Checked at the ledger's scale (numeric(19,4)), so an amount that rounds
    # to zero or past the column's capacity is refused rather than stored.
    amount = amount.to_d.round(4) if amount.is_a?(Numeric)
    refuse!(:invalid_transaction) unless amount.is_a?(Numeric) && amount.positive? && amount < MAX_AMOUNT && date.is_a?(Date) && known_currency?(currency)
    refuse!(:awaiting_bank, date: I18n.l(bank_wait_until)) if account.linked? && awaiting_bank?

    entry = nil
    with_file_copy do |copy|
      with_lock do
        raise ActiveRecord::RecordNotFound unless writable_account?(account, user)
        refuse!(:already_linked) if transaction_id?
        # Checked again on the locked row: the date may have changed during the copy.
        refuse!(:awaiting_bank, date: I18n.l(bank_wait_until)) if account.linked? && awaiting_bank?

        entry = account.entries.create!(
          name: name,
          date: date,
          amount: amount,
          currency: currency,
          entryable: Transaction.new(merchant: suggested_merchant(name), extra: { "created_from_receipt" => true })
        )
        entry.lock_saved_attributes!
        entry.mark_user_modified!
        attach_to!(entry.transaction, copy, created: true)
      end
    end

    # The entry and link are committed at this point, so a failed enqueue must
    # not fail the request: a retry would only see the receipt as already linked.
    enqueue_after_create(entry, :sync_account_later)
    enqueue_after_create(entry, :apply_immediate_rules_later)
    entry
  end

  # Dismissing a suggested receipt drops the suggestion without remembering it
  # as rejected, so reopening the receipt can suggest it again.
  def dismiss!
    with_lock do
      attrs = { dismissed_at: Time.current }
      attrs.merge!(linked_transaction: nil, match_status: nil, linked_at: nil) if suggested?
      update!(attrs)
    end
  end

  def reopen!
    update!(dismissed_at: nil)
  end

  # The family's merchant named like the receipt's merchant, or like `name`.
  def suggested_merchant(name = nil)
    return nil if merchant_name.blank? && name.blank?

    family.merchants.where("LOWER(name) = ?", (merchant_name.presence || name).downcase).first
  end

  private
    def enqueue_after_create(entry, method)
      entry.public_send(method)
    rescue StandardError => e
      DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{id}: #{method} failed for Entry##{entry.id}: #{e.class}",
                            source: "receipt_transaction", family: family, user_id: uploaded_by_id)
    end

    def enqueue_failed!(reason)
      DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{id}: could not queue reading: #{reason}",
                            source: "receipt_extraction", family: family, user_id: uploaded_by_id)
      update_columns(extraction_status: "failed", extraction_error: "enqueue_failed", updated_at: Time.current)
    end

    def auto_matchable?
      # A receipt that could not be read is matched once the user has typed in its details.
      !transaction_id? && !dismissed_at? && !extraction_pending? && uploaded_by_id? && amount.present? && date.present? && currency.present?
    end

    # The transaction's copy is uploaded before the database work, so a storage
    # error fails the link instead of leaving it pointing at a missing file. The
    # copy is removed again when the link does not happen.
    def with_file_copy
      copy = self.class.upload_blob!(file.download, filename: filename, content_type: content_type)
      yield copy
    rescue StandardError
      self.class.discard_blob(copy)
      raise
    end

    # Runs inside the receipt's row lock, so two clicks cannot link it twice. A
    # suggestion still waiting for the user is replaced by this link.
    def attach_to!(transaction, copy, created:)
      refuse!(:already_linked) if transaction_id? && !suggested?

      transaction.with_lock do
        if transaction.attachments.count >= Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
          refuse!(:too_many_attachments, max: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION)
        end

        unless transaction.attachments.attach(copy)
          errors.merge!(transaction.errors)
          raise ActiveRecord::RecordInvalid, self
        end
        update!(linked_transaction: transaction, linked_at: Time.current, dismissed_at: nil, created_transaction: created, match_status: "confirmed")
      end
    end

    def refuse_changed_suggestion!(expected_transaction_id)
      refuse!(:not_suggested) unless suggested?
      refuse!(:suggestion_changed) if expected_transaction_id.present? && expected_transaction_id.to_s != self.transaction_id.to_s
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
end
