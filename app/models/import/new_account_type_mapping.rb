# Lets the user pick the account type for each account an import will create.
# Keys are the account names from the file that have no matching family account;
# the value is an Accountable type, pre-filled with a guess from the name.
class Import::NewAccountTypeMapping < Import::Mapping
  NAME_SUGGESTIONS = [
    [ "Loan", /\b(loan|mortgage|heloc)\b/i ],
    [ "CreditCard", /\b(credit\s*card|card|visa|mastercard|amex|american express|discover)\b/i ],
    [ "Investment", /\b(brokerage|invest\w*|401\s*\(?k\)?|403\s*\(?b\)?|ira|roth|retirement|pension)\b/i ],
    [ "Crypto", /\b(crypto|bitcoin|btc|ethereum|coinbase)\b/i ]
  ].freeze

  validates :value, presence: true, inclusion: { in: Accountable::TYPES }

  after_initialize :suggest_value, if: :new_record?

  class << self
    def mappables_by_key(import)
      Import::AccountMapping.mappables_by_key(import).filter_map { |key, account| [ key, nil ] if key.present? && account.nil? }.to_h
    end

    def suggested_type_for(name)
      NAME_SUGGESTIONS.find { |_type, pattern| name.to_s.match?(pattern) }&.first || "Depository"
    end

    def accountable_type_for(import, name)
      value = import.mappings.new_account_types.find_by(key: name)&.value
      value.in?(Accountable::TYPES) ? value : suggested_type_for(name)
    end
  end

  def selectable_values
    Accountable::TYPES.map { |type| [ type.constantize.singular_display_name, type ] }
  end

  def requires_selection?
    true
  end

  def values_count
    import.rows.where(account: key).count
  end

  def create_mappable!
    # no-op: the chosen type is read when the account mapping creates the account
  end

  private
    def suggest_value
      self.value ||= self.class.suggested_type_for(key) if key.present?
    end
end
