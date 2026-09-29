# A contract the family is bound by: insurance, phone, internet, energy,
# subscriptions, rent. Bills answers "what is due and was it paid"; a contract
# answers "what am I bound by, until when, how do I get out, and where is the
# paperwork". Design and decisions: docs/llm-guides/contracts.md.
#
# Visibility mirrors accounts: the owner plus the users it is explicitly shared
# with. There is no admin override, and a related account grants nothing.
class Contract < ApplicationRecord
  include Encryptable, Contract::Detailable

  KIND_ICONS = {
    "insurance" => "shield",
    "mobile" => "smartphone",
    "internet" => "wifi",
    "energy" => "zap",
    "streaming" => "tv",
    "software" => "app-window",
    "fitness" => "dumbbell",
    "membership" => "id-card",
    "rent" => "house",
    "other" => "file-text"
  }.freeze

  # Ordered weakest to strongest. The owner is not a share; it outranks all.
  PERMISSION_RANKS = { read_only: 1, read_write: 2, full_control: 3, owner: 4 }.freeze

  MAX_DOCUMENT_LINKS = 10

  belongs_to :family
  belongs_to :owner, class_name: "User"
  belongs_to :account, optional: true
  belongs_to :merchant, optional: true
  belongs_to :replaced_by, class_name: "Contract", optional: true

  has_many :contract_shares, dependent: :destroy
  has_many :shared_users, through: :contract_shares, source: :user
  has_many :recurring_transactions, dependent: :nullify
  has_many :contract_documents, dependent: :destroy
  has_many :predecessors, class_name: "Contract", foreign_key: :replaced_by_id, dependent: :nullify, inverse_of: :replaced_by

  if encryption_ready?
    encrypts :contract_number
    encrypts :customer_number
  end

  enum :kind, KIND_ICONS.keys.index_with(&:itself), validate: true
  enum :status, { active: "active", cancellation_sent: "cancellation_sent",
                  cancelled: "cancelled", ended: "ended" }, validate: true
  enum :notice_period_unit, { days: "days", weeks: "weeks", months: "months" },
       prefix: :notice_in, validate: { allow_nil: true }
  enum :notice_anchor, { end_of_term: "end_of_term", end_of_month: "end_of_month", any_day: "any_day" },
       prefix: :notice_to, validate: { allow_nil: true }

  normalizes :contract_number, :customer_number, :provider_name, :service_phone, :claims_phone,
             :service_email, :portal_url, with: ->(value) { value.strip.presence }

  before_validation :assign_default_owner, on: :create
  before_validation :normalize_document_links

  validates :name, presence: true, length: { maximum: 255 }
  validates :minimum_term_months, :notice_period_value,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :renewal_period_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :provider_present
  validate :notice_period_complete
  validate :ends_after_start
  validate :references_belong_to_family
  validate :owner_belongs_to_family
  validate :portal_url_is_http
  validate :document_links_are_http

  after_create_commit :auto_share_with_family, if: -> { family.share_all_by_default? }

  scope :alphabetically, -> { order(Arel.sql("LOWER(contracts.name)")) }

  # Everything a user may see: owned or shared with them in any tier. A
  # subquery rather than a join, so the scope stays free of DISTINCT and can be
  # ordered by any expression.
  scope :accessible_by, ->(user) {
    where(owner_id: user.id).or(where(id: ContractShare.where(user_id: user.id).select(:contract_id)))
  }

  # Contracts a user may change (fields, documents, notes, linked bills).
  scope :editable_by, ->(user) {
    where(owner_id: user.id).or(
      where(id: ContractShare.where(user_id: user.id, permission: ContractShare::EDIT_PERMISSIONS).select(:contract_id))
    )
  }

  class << self
    def icon_for(kind)
      KIND_ICONS.fetch(kind.to_s, KIND_ICONS["other"])
    end

    def kind_options
      kinds.keys.map { |kind| [ I18n.t("contracts.kinds.#{kind}"), kind ] }
    end

    # Public: views render portal and document links only when this holds.
    def http_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end
  end

  def icon
    self.class.icon_for(kind)
  end

  def provider_display_name
    merchant&.name.presence || provider_name
  end

  # :owner, :full_control, :read_write, :read_only, or nil for no access.
  # Reads the loaded shares when present so list pages cost no extra query.
  def permission_for(user)
    return if user.nil?
    return :owner if owner_id == user.id

    share = if contract_shares.loaded?
      contract_shares.find { |s| s.user_id == user.id }
    else
      contract_shares.find_by(user_id: user.id)
    end
    share&.permission&.to_sym
  end

  def viewable_by?(user)
    permission_for(user).present?
  end

  def editable_by?(user)
    permission_at_least?(user, :read_write)
  end

  # Sharing, deleting and changing the owner.
  def manageable_by?(user)
    permission_at_least?(user, :full_control)
  end

  # read_only sees numbers masked; everyone who may edit sees them in full.
  def numbers_visible_to?(user)
    editable_by?(user)
  end

  def masked_contract_number
    self.class.mask(contract_number)
  end

  def masked_customer_number
    self.class.mask(customer_number)
  end

  # Short values would survive "last 4" whole, so they mask entirely.
  def self.mask(value)
    return if value.blank?

    value = value.to_s
    return "••••" if value.length <= 4

    "•••• #{value.last(4)}"
  end

  # Contract status is set by the user, but a fixed end date that has passed
  # ends the contract for display whether or not anyone recorded it.
  # The end date itself still counts as open unless the status is "ended".
  def effectively_ended?(on: Date.current)
    ended? || (ends_on.present? && ends_on < on)
  end

  def display_status(on: Date.current)
    effectively_ended?(on: on) ? "ended" : status
  end

  def open?(on: Date.current)
    !effectively_ended?(on: on)
  end

  def notice_schedule(today: Date.current)
    Contract::NoticeSchedule.new(self, today: today).call
  end

  # The last day to give notice for the next possible end, or nil when there
  # is nothing to miss (cancellable any time, already cancelled, or terms not
  # recorded).
  def notice_deadline(today: Date.current)
    notice_schedule(today: today).notice_deadline
  end

  # The linked bills this user may see. Bills keep their own visibility, so a
  # shared contract never reveals a payment from an account the viewer cannot
  # reach.
  def visible_recurring_transactions_for(user)
    recurring_transactions.accessible_by(user)
  end

  def hidden_recurring_transactions_for?(user)
    recurring_transactions.where.not(id: visible_recurring_transactions_for(user).select(:id)).exists?
  end

  # Yearly cost across the active linked bills the user can see, in the family
  # currency. Returns [money_or_nil, unconvertible_count]; nil when no active
  # linked bills are visible. Bills raising Money::ConversionError are omitted
  # and counted; the total is zero if every visible active bill fails conversion.
  def annual_cost_for(user)
    self.class.annual_costs_for([ self ], user).fetch(id)
  end

  # Returns a hash of contract IDs to annual_cost_for results. Pass contracts
  # from one family; all totals use the first contract's family currency and
  # exchange rates for Date.current. An empty list returns {}.
  def self.annual_costs_for(contracts, user)
    return {} if contracts.empty?

    family = contracts.first.family
    target = family.currency
    series_by_contract = RecurringTransaction.accessible_by(user)
                                             .where(contract_id: contracts.map(&:id), status: "active")
                                             .includes(:recurrence_rules)
                                             .group_by(&:contract_id)

    contracts.to_h do |contract|
      series = series_by_contract.fetch(contract.id, [])
      next [ contract.id, [ nil, 0 ] ] if series.empty?

      unconvertible = 0
      total = series.reduce(Money.new(0, target)) do |sum, recurring|
        sum + (recurring.monthly_equivalent_amount.abs * 12).exchange_to(target)
      rescue Money::ConversionError
        unconvertible += 1
        sum
      end

      [ contract.id, [ total, unconvertible ] ]
    end
  end

  # Sorted by next_due_date, because the stored next_expected_date is only a
  # cached hint that can lag behind settled payments.
  def next_payment_for(user)
    visible_recurring_transactions_for(user)
      .where(status: "active")
      .min_by(&:next_due_date)
  end

  # Records that a cancellation went out. The caller decides whether the
  # linked bills end with the contract; the default leaves them running and the
  # bill pane flags them once the contract has ended.
  # A blank ends_on preserves the recorded end date. Contract and optional bill
  # updates share a transaction; validation failures raise ActiveRecord::RecordInvalid.
  # Pass bills: to limit which linked bills may be ended, for example to the
  # ones the acting user may change.
  def record_cancellation!(sent_on:, ends_on: nil, end_linked_bills: false, bills: recurring_transactions)
    transaction do
      update!(status: "cancellation_sent", cancelled_on: sent_on, ends_on: ends_on.presence || self.ends_on)
      end_linked_bills_on!(self.ends_on, bills: bills) if end_linked_bills && self.ends_on.present?
    end
  end

  # Records provider confirmation without changing the end date or linked bills.
  # Raises ActiveRecord::RecordInvalid if validation fails.
  def confirm_cancellation!(confirmed_on:)
    update!(status: "cancelled", cancellation_confirmed_on: confirmed_on)
  end

  # A retention offer was accepted, or the cancellation was sent in error.
  # Clears cancellation dates and restores active status, preserving ends_on
  # and linked bill end dates. Raises ActiveRecord::RecordInvalid on validation failure.
  def withdraw_cancellation!
    update!(status: "active", cancelled_on: nil, cancellation_confirmed_on: nil)
  end

  # Marks the contract ended, using ended_on only when no end date is recorded.
  # Leaves linked bills unchanged; raises ActiveRecord::RecordInvalid on validation failure.
  def mark_ended!(ended_on: Date.current)
    update!(status: "ended", ends_on: ends_on.presence || ended_on)
  end

  # Linked, still-running bills whose contract has already ended. The bill
  # pane offers to end them.
  def running_bills_after_end
    return RecurringTransaction.none unless effectively_ended?

    end_date = ends_on || updated_at.to_date
    recurring_transactions.where(status: "active")
                          .where("recurring_transactions.end_mode <> 'on_date' OR recurring_transactions.end_on IS NULL OR recurring_transactions.end_on > ?", end_date)
  end

  # Sets the end date on the active, inactive and paused linked bills within
  # bills (all linked bills by default; callers acting for a user pass the ones
  # that user may change). Raises ActiveRecord::RecordInvalid on validation failure;
  # earlier updates remain unless the caller wraps the operation in a transaction.
  def end_linked_bills_on!(date, bills: recurring_transactions)
    bills.where(contract_id: id, status: %w[active inactive paused]).find_each do |recurring|
      recurring.update!(end_mode: "on_date", end_on: date)
    end
  end

  # Possible duplicates: same provider and same contract number in the family.
  # Numbers are encrypted non-deterministically, so the comparison runs in Ruby
  # over the family's (few) contracts rather than in SQL.
  def possible_duplicates
    return Contract.none if contract_number.blank?

    candidates = family.contracts.where.not(id: id)
    candidates = merchant_id.present? ? candidates.where(merchant_id: merchant_id) : candidates.where("LOWER(provider_name) = ?", provider_name.to_s.downcase)
    ids = candidates.select { |other| other.contract_number.to_s.casecmp?(contract_number.to_s) }.map(&:id)
    family.contracts.where(id: ids)
  end

  # Shares this contract with every other member, as accounts are when the
  # family shares by default. Guests read only, everyone else read and write.
  def auto_share_with_family!
    records = family.users.where.not(id: owner_id).pluck(:id, :role).map do |user_id, role|
      { contract_id: id, user_id: user_id,
        permission: role == "guest" ? "read_only" : "read_write",
        created_at: Time.current, updated_at: Time.current }
    end

    ContractShare.insert_all(records, unique_by: %i[contract_id user_id]) if records.any?
  end

  private

    def permission_at_least?(user, minimum)
      permission = permission_for(user)
      permission.present? && PERMISSION_RANKS.fetch(permission) >= PERMISSION_RANKS.fetch(minimum)
    end

    def assign_default_owner
      return if owner.present? || family.nil?

      self.owner = if Current.user.present? && Current.user.family_id == family_id
        Current.user
      else
        family.users.where(role: %w[admin super_admin]).order(:created_at, :id).first ||
          family.users.order(:created_at, :id).first
      end
    end

    def auto_share_with_family
      auto_share_with_family!
    end

    def normalize_document_links
      links = Array(document_links).filter_map do |link|
        url = link.is_a?(Hash) ? link["url"] || link[:url] : link
        label = link.is_a?(Hash) ? link["label"] || link[:label] : nil
        next if url.to_s.strip.blank?

        { "url" => url.to_s.strip, "label" => label.to_s.strip.presence }.compact
      end
      self.document_links = links
    end

    def provider_present
      return if merchant_id.present? || provider_name.present?

      errors.add(:provider_name, :blank)
    end

    def notice_period_complete
      return if notice_period_value.nil? == notice_period_unit.nil?

      errors.add(:notice_period_value, :incomplete)
    end

    def ends_after_start
      return if started_on.blank? || ends_on.blank? || ends_on >= started_on

      errors.add(:ends_on, :before_start)
    end

    def references_belong_to_family
      errors.add(:account, :invalid) if account && account.family_id != family_id
      errors.add(:merchant, :invalid) if merchant.is_a?(FamilyMerchant) && merchant.family_id != family_id
      errors.add(:replaced_by, :invalid) if replaced_by && (replaced_by.family_id != family_id || replaced_by_id == id)
    end

    def owner_belongs_to_family
      errors.add(:owner, :invalid) if owner && owner.family_id != family_id
    end

    def portal_url_is_http
      return if portal_url.blank? || self.class.http_url?(portal_url)

      errors.add(:portal_url, :invalid)
    end

    def document_links_are_http
      if document_links.size > MAX_DOCUMENT_LINKS
        errors.add(:document_links, :too_many, count: MAX_DOCUMENT_LINKS)
      elsif document_links.any? { |link| !self.class.http_url?(link["url"]) }
        errors.add(:document_links, :invalid)
      end
    end
end
