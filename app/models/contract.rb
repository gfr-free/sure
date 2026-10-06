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

  # How far back a linked bill's price change still shows on the contract.
  PRICE_CHANGE_WINDOW = 12.months

  # How far back an ended contract still counts towards the savings.
  SAVINGS_WINDOW = 12.months

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
  # "ended" means the user recorded an end date (cancelled or ended, one
  # step). Until that date the contract still runs and shows as ending.
  enum :status, { active: "active", ended: "ended" }, validate: true
  enum :notice_period_unit, { days: "days", weeks: "weeks", months: "months" },
       prefix: :notice_in, validate: { allow_nil: true }
  enum :notice_anchor, { end_of_term: "end_of_term", end_of_month: "end_of_month", any_day: "any_day" },
       prefix: :notice_to, validate: { allow_nil: true }

  normalizes :contract_number, :customer_number, :service_phone, :claims_phone,
             :service_email, :portal_url, with: ->(value) { value.strip.presence }

  before_validation :assign_default_owner, on: :create
  before_validation :normalize_document_links
  before_validation :clear_notice_terms, if: :notice_not_required?

  validates :name, presence: true, length: { maximum: 255 }
  validates :minimum_term_months, :notice_period_value,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :renewal_period_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :ends_on, presence: true, if: :ended?
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

    # The merchant a provider name stands for, among those the user can pick:
    # the family's own merchants and the ones on their transactions. Matching
    # ignores case and surrounding blanks. Returns nil when none matches.
    def merchant_named(family, user, name)
      name = name.to_s.strip
      return if name.blank?

      family.available_merchants_for(user).where("LOWER(merchants.name) = ?", name.downcase)
            .order(Arel.sql("CASE WHEN merchants.type = 'FamilyMerchant' THEN 0 ELSE 1 END"), :created_at).first
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
    merchant&.name
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

  # A contract runs through its end date and has ended from the day after.
  def effectively_ended?(on: Date.current)
    ends_on.present? && ends_on < on
  end

  # "active", "ending" (an end is recorded but not reached) or "ended".
  def display_status(on: Date.current)
    return "ended" if effectively_ended?(on: on)

    ended? ? "ending" : "active"
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

  # The end of the price guarantee an energy contract records, or nil.
  def price_guarantee_until
    typed_detail(:price_guarantee_until) if energy?
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
  # currency. Returns [money_or_nil, unconvertible_count, unconverted]; nil when
  # no active linked bills are visible. Bills raising Money::ConversionError are
  # left out of the total and counted; unconverted holds their yearly cost in
  # their own currency (a hash of currency code to Money), so a contract billed
  # in another currency still shows what it costs. The total is zero if every
  # visible active bill fails conversion.
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
      next [ contract.id, [ nil, 0, {} ] ] if series.empty?

      unconvertible = 0
      unconverted = {}
      total = series.reduce(Money.new(0, target)) do |sum, recurring|
        yearly = recurring.monthly_equivalent_amount.abs * 12
        sum + yearly.exchange_to(target)
      rescue Money::ConversionError
        unconvertible += 1
        code = yearly.currency.iso_code
        unconverted[code] = (unconverted[code] || Money.new(0, code)) + yearly
        sum
      end

      [ contract.id, [ total, unconvertible, unconverted ] ]
    end
  end

  # Adds up annual_costs_for results into one of the same shape, keeping the
  # bills without an exchange rate apart by currency. [nil, 0, {}] when none
  # of the contracts has a known cost.
  def self.sum_costs(costs)
    known = costs.compact.select(&:first)
    return [ nil, 0, {} ] if known.empty?

    total = known.sum(Money.new(0, known.first.first.currency)) { |money, _, _| money }
    unconverted = known.map { |cost| cost[2].to_h }.reduce({}) { |sum, amounts| sum.merge(amounts) { |_, a, b| a + b } }
    [ total, known.sum { |cost| cost[1].to_i }, unconverted ]
  end

  # What the contracts that ended in the last twelve months cost per year, less
  # what replaced them: [money_or_nil, count]. Pass every contract the user can
  # see (successors are looked up among them) and, when at hand, their
  # annual_costs_for result.
  #
  # A chain of replacements counts once, from its first contract that ended in
  # the window to the open contract at its end, and several contracts replaced
  # by one (phone and internet by a bundle) share that one successor's cost.
  # An ended contract counts the bills that ended with it (the last amount, as
  # the bills have ended too); a bill still running is not saved money. The
  # total is negative when the successors cost more. nil when no contract
  # ended in the window.
  def self.annual_savings_for(contracts, user, costs: nil, today: Date.current)
    since = today - SAVINGS_WINDOW
    ended = contracts.select { |contract| contract.ends_on.present? && contract.ends_on < today && contract.ends_on >= since }
    return [ nil, 0 ] if ended.empty?

    target = ended.first.family.currency
    by_id = contracts.index_by(&:id)
    # A contract that replaced another one ended in the window is part of that
    # chain, not a saving of its own.
    replacements = ended.filter_map(&:replaced_by_id).to_set
    roots = ended.reject { |contract| replacements.include?(contract.id) }

    finals = roots.filter_map { |contract| final_successor(contract, by_id, today) }.uniq
    costs ||= annual_costs_for(finals, user)
    successor_cost = finals.sum(Money.new(0, target)) { |contract| costs.dig(contract.id, 0) || Money.new(0, target) }

    [ ended_bills_cost(roots, user, target) - successor_cost, ended.size ]
  end

  def self.final_successor(contract, by_id, today)
    seen = Set.new
    current = by_id[contract.replaced_by_id]
    while current && seen.add?(current.id)
      return current if current.open?(on: today)

      current = by_id[current.replaced_by_id]
    end
  end
  private_class_method :final_successor

  def self.ended_bills_cost(contracts, user, target)
    ends_on = contracts.to_h { |contract| [ contract.id, contract.ends_on ] }

    RecurringTransaction.accessible_by(user)
                        .where(contract_id: ends_on.keys)
                        .where.not(end_on: nil)
                        .includes(:recurrence_rules)
                        .select { |recurring| recurring.end_on >= ends_on.fetch(recurring.contract_id).prev_month }
                        .sum(Money.new(0, target)) do |recurring|
      (recurring.monthly_equivalent_amount.abs * 12).exchange_to(target)
    rescue Money::ConversionError
      Money.new(0, target)
    end
  end
  private_class_method :ended_bills_cost

  # Price changes of the linked bills the user can see, newest first, from the
  # last twelve months by default. Bills keep their own visibility, so a shared
  # contract never reveals a price from an account the viewer cannot reach.
  def self.price_changes_for(contracts, user, since: PRICE_CHANGE_WINDOW.ago.to_date)
    RecurringPriceChange.joins(:recurring_transaction)
                        .merge(RecurringTransaction.accessible_by(user))
                        .where(recurring_transactions: { contract_id: Array(contracts).map(&:id) })
                        .where(effective_on: since..Date.current)
                        .order("recurring_price_changes.effective_on DESC, recurring_price_changes.created_at DESC")
  end

  # Returns a hash of contract IDs to the newest price increase among their
  # visible active bills. A bill counts only when its own latest change was an
  # increase, so a price that went up and back down again carries no badge,
  # while a cut on one bill never hides a rise on another. Amounts compare as
  # absolute values, like the contract_price_increase insight.
  def self.recent_price_increases_for(contracts, user)
    return {} if contracts.empty?

    price_changes_for(contracts, user)
      .where(recurring_transactions: { status: "active" })
      .includes(:recurring_transaction)
      .to_a
      .uniq(&:recurring_transaction_id)
      .select { |change| change.new_amount.abs > change.previous_amount.abs }
      .group_by { |change| change.recurring_transaction.contract_id }
      .transform_values(&:first)
  end

  def price_changes_for(user)
    self.class.price_changes_for([ self ], user)
  end

  # Sorted by next_due_date, because the stored next_expected_date is only a
  # cached hint that can lag behind settled payments.
  def next_payment_for(user)
    visible_recurring_transactions_for(user)
      .where(status: "active")
      .min_by(&:next_due_date)
  end

  # Records the end of the contract, whether it was cancelled or simply runs
  # out: one date, from which nothing is owed any more. The linked bills within
  # bills end on the same day, so Bills stops expecting payments afterwards;
  # callers acting for a user pass the bills that user may change. Contract and
  # bill updates share a transaction and raise ActiveRecord::RecordInvalid.
  def end_contract!(on:, bills: recurring_transactions)
    transaction do
      update!(status: "ended", ends_on: on)
      end_linked_bills_on!(on, bills: bills)
    end
  end

  # Takes back a recorded end, after a retention offer for example. Bills that
  # were ended on that date run on again.
  def reopen!(bills: recurring_transactions)
    previous_end = ends_on

    transaction do
      update!(status: "active", ends_on: nil)
      next if previous_end.nil?

      bills.where(contract_id: id, end_mode: "on_date", end_on: previous_end).find_each do |recurring|
        recurring.update!(end_mode: "never", end_on: nil)
      end
    end
  end

  # Linked, still-running bills whose contract has already ended. The bill
  # pane offers to end them.
  def running_bills_after_end
    return RecurringTransaction.none unless effectively_ended?

    end_date = ends_on
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

    return Contract.none if merchant_id.blank?

    candidates = family.contracts.where.not(id: id).where(merchant_id: merchant_id)
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
        role = link.is_a?(Hash) ? (link["role"] || link[:role]).to_s : ""
        next if url.to_s.strip.blank?

        { "url" => url.to_s.strip, "label" => label.to_s.strip.presence,
          "role" => role.presence_in(ContractDocument::ROLES) }.compact
      end
      self.document_links = links
    end

    # A contract that needs no notice keeps no notice terms, so no deadline or
    # reminder can come from a period left over from before.
    def clear_notice_terms
      self.notice_period_value = nil
      self.notice_period_unit = nil
      self.notice_anchor = nil
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
