# How an account is taxed (taxes on returns, decision E20, STEUER.md S-1/S-2).
#
# - The tax treatment comes from TaxTreatable: investment accounts take it
#   from the subtype, crypto and (new) bank accounts store it.
# - `tax_withheld_at_source`: whether the bank books returns net (it pays the
#   tax) or gross (the tax is due later, S3). Nil follows the owner's profile.
# - `tax_allowance_allocation`: the share of the owner's allowance given to
#   this account's bank (exemption order).
# - `january_tax_debit`: a tax debited every January, such as the German
#   Vorabpauschale (S7). It shows up in the account forecast.
#
# Tax belongs to a person, not the family (S4): the account's owner. A joint
# account names a second person and the owner's share of its returns
# (E21 T1, 50/50 unless set). Securities and crypto accounts keep loss pots
# (LossPot, E21 T2/T4), entered here as balances from a bank statement.
# The arithmetic lives in Tax::Estimate.
module Account::Taxation
  extend ActiveSupport::Concern

  TAXABLE_TYPES = %w[Depository Investment Crypto].freeze
  WITHHELD_CHOICES = %w[profile yes no].freeze
  JANUARY_TAX_DEBIT_DAY = 2

  DEFAULT_OWNER_SHARE = 50

  included do
    belongs_to :tax_joint_user, class_name: "User", optional: true
    has_many :loss_pots, dependent: :destroy

    validates :tax_allowance_allocation, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validates :january_tax_debit, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validates :tax_owner_share, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
    validate :tax_joint_user_must_be_another_family_member
    validate :loss_pot_input_must_be_valid

    before_validation :apply_tax_treatment_choice
    after_save :save_loss_pot_input
  end

  attr_reader :tax_treatment_choice

  # Bank accounts store their treatment on the accountable; the account form
  # writes it through this attribute so it stays one form. Blank follows the
  # subtype.
  def tax_treatment_choice=(value)
    @tax_treatment_choice = value.to_s
  end

  def tax_capable?
    accountable_type.in?(TAXABLE_TYPES)
  end

  # Returns on this account count for the owner's tax: a capable account
  # whose treatment is taxable (nil reads as taxable, see TaxTreatable).
  def returns_taxable?
    tax_capable? && taxable?
  end

  def tax_person
    owner
  end

  def tax_joint?
    tax_joint_user_id.present?
  end

  # The owner's share of a joint account's returns in percent.
  def effective_tax_owner_share
    (tax_owner_share || DEFAULT_OWNER_SHARE).to_d
  end

  # Who pays tax on this account's returns, and their share (0..1). The owner
  # alone, or the owner and the joint person split by `tax_owner_share`. The
  # joint person only counts while they are another member of the family the
  # account is shared with; a stale entry (the share was removed, the account
  # moved family or passed to them) leaves the owner alone.
  def tax_shares
    return {} if owner.nil?
    return { owner => 1.to_d } unless tax_joint_partner?

    owner_share = effective_tax_owner_share / 100
    { owner => owner_share, tax_joint_user => 1 - owner_share }.reject { |_, share| share.zero? }
  end

  def tax_share_for(user)
    return 0.to_d if user.nil?

    tax_shares.find { |person, _| person.id == user.id }&.last || 0.to_d
  end

  def loss_pots_capable?
    accountable_type.in?(LossPot::ACCOUNT_TYPES)
  end

  def loss_pot(kind)
    loss_pots.find { |pot| pot.kind == kind }
  end

  # Form fields for the loss pots (V-1): one balance per kind, the date of
  # the statement it comes from and whether balances carry into the next
  # year. Saving writes a balance for that date where the amount or the date
  # changed; an empty field leaves the pot as it is.
  LossPot::KINDS.each do |kind|
    define_method(:"loss_pot_#{kind}_amount") do
      return @loss_pot_input[kind] if @loss_pot_input&.key?(kind)

      loss_pot(kind)&.latest_snapshot&.amount
    end

    define_method(:"loss_pot_#{kind}_amount=") do |value|
      (@loss_pot_input ||= {})[kind] = value.to_s.strip
    end
  end

  def loss_pot_as_of
    return @loss_pot_input["as_of"] if @loss_pot_input&.key?("as_of")

    stored_loss_pot_as_of
  end

  def loss_pot_as_of=(value)
    (@loss_pot_input ||= {})["as_of"] = value.to_s.strip
  end

  def loss_pot_carry_forward
    return ActiveModel::Type::Boolean.new.cast(@loss_pot_input["carry_forward"]) if @loss_pot_input&.key?("carry_forward")

    stored_loss_pot_carry_forward
  end

  def loss_pot_carry_forward=(value)
    (@loss_pot_input ||= {})["carry_forward"] = value
  end

  def tax_profile_for(year)
    TaxProfile.for(tax_person, year)
  end

  # Whether the bank books returns net. Without the account's own setting
  # the owner's profile decides; without a profile, banks are assumed to
  # withhold, which keeps every figure gross as before.
  def tax_withheld_at_source_in?(year)
    return tax_withheld_at_source unless tax_withheld_at_source.nil?

    profile = tax_profile_for(year)
    profile.nil? || profile.withheld_at_source_default
  end

  def tax_withheld_choice
    case tax_withheld_at_source
    when true then "yes"
    when false then "no"
    else "profile"
    end
  end

  def tax_withheld_choice=(value)
    self.tax_withheld_at_source = case value.to_s
    when "yes" then true
    when "no" then false
    end
  end

  # The January debit falling on or after `from` and on or before `to`.
  def january_tax_debits_between(from, to)
    return [] unless january_tax_debit.to_d.positive?

    (from.year..to.year).filter_map do |year|
      date = Date.new(year, 1, JANUARY_TAX_DEBIT_DAY)
      date if date >= from && date <= to
    end
  end

  # Where the exemption order sits: the bank's name, else the account's.
  def tax_institution_label
    institution_name.presence || provider&.institution_name.presence || name
  end

  private
    def tax_joint_partner?
      return false unless tax_joint? && tax_joint_user && tax_joint_user_id != owner_id
      return false unless tax_joint_user.family_id == family_id

      if account_shares.loaded?
        account_shares.any? { |share| share.user_id == tax_joint_user_id }
      else
        account_shares.exists?(user_id: tax_joint_user_id)
      end
    end

    # The joint person must already see the account: it is shared with them.
    # Their tax estimate lists it, so naming someone cannot reveal an account
    # they were not given. Checked when the person is set, so an entry that
    # later goes stale never blocks other saves (tax_shares ignores it).
    def tax_joint_user_must_be_another_family_member
      return unless tax_joint? && will_save_change_to_tax_joint_user_id?

      errors.add(:tax_joint_user_id, :invalid) unless tax_joint_partner?
    end

    def stored_loss_pot_as_of
      loss_pots.filter_map { |pot| pot.latest_snapshot&.date }.max
    end

    def stored_loss_pot_carry_forward
      loss_pots.empty? || loss_pots.all?(&:carry_forward?)
    end

    def parsed_loss_pot_amount(kind)
      raw = @loss_pot_input&.dig(kind)
      return nil if raw.blank?

      BigDecimal(raw, exception: false)
    end

    def parsed_loss_pot_date
      raw = @loss_pot_input&.dig("as_of")
      return nil if raw.blank?

      parsed_loss_pot_date_from(@loss_pot_input) || :invalid
    end

    def loss_pot_input_must_be_valid
      return if @loss_pot_input.blank?

      LossPot::KINDS.each do |kind|
        raw = @loss_pot_input[kind]
        next if raw.blank?

        amount = parsed_loss_pot_amount(kind)
        errors.add(:"loss_pot_#{kind}_amount", :invalid) if amount.nil? || amount.negative?
      end

      return unless LossPot::KINDS.any? { |kind| @loss_pot_input[kind].present? }

      errors.add(:base, :invalid) unless loss_pots_capable?
      date = parsed_loss_pot_date
      errors.add(:loss_pot_as_of, :invalid) if date == :invalid || (date.is_a?(Date) && date > Date.current)
    end

    # Writes a balance per pot only where something changed: the form shows
    # each pot's latest amount but one date for both, so an untouched pot
    # must not get a new balance at the other pot's date. The carry-forward
    # switch likewise only overwrites the pots when it was changed.
    def save_loss_pot_input
      input = @loss_pot_input
      @loss_pot_input = nil
      return if input.blank? || !loss_pots_capable?

      shown_date = stored_loss_pot_as_of
      date = parsed_loss_pot_date_from(input) || Date.current
      carry_forward = nil
      if input.key?("carry_forward")
        wanted = ActiveModel::Type::Boolean.new.cast(input["carry_forward"]) != false
        carry_forward = wanted unless wanted == stored_loss_pot_carry_forward
      end

      LossPot::KINDS.each do |kind|
        pot = loss_pot(kind)
        amount = input[kind].presence && BigDecimal(input[kind], exception: false)
        latest = pot&.latest_snapshot
        unchanged = latest && amount == latest.amount && date == shown_date

        if amount && !unchanged
          pot ||= loss_pots.build(kind: kind)
          pot.carry_forward = carry_forward unless carry_forward.nil?
          pot.save!
          pot.snapshots.find_or_initialize_by(date: date).update!(amount: amount, source: "manual")
        elsif pot && !carry_forward.nil?
          pot.update!(carry_forward: carry_forward)
        end
      end

      loss_pots.reset
    end

    def parsed_loss_pot_date_from(input)
      Date.iso8601(input["as_of"].to_s)
    rescue Date::Error
      nil
    end

    def apply_tax_treatment_choice
      return if @tax_treatment_choice.nil?
      return unless accountable.is_a?(Depository)

      accountable.tax_treatment = @tax_treatment_choice.presence_in(Depository::TAX_TREATMENTS)
    end
end
