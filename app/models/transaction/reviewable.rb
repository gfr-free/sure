# The manual review mark on a transaction: flagged ("look at this again") or
# reviewed ("checked, nothing to do"). One column, so the two exclude each
# other; nil means open. Provider syncs never write it.
module Transaction::Reviewable
  extend ActiveSupport::Concern

  REVIEW_STATES = %w[flagged reviewed].freeze
  # Filter value for transactions with no mark ("open").
  REVIEW_STATE_OPEN = "open".freeze
  REVIEW_STATE_FILTER_VALUES = [ REVIEW_STATE_OPEN, *REVIEW_STATES ].freeze

  included do
    belongs_to :review_state_changed_by, class_name: "User", optional: true

    validates :review_state, inclusion: { in: REVIEW_STATES }, allow_nil: true

    scope :review_flagged, -> { where(review_state: "flagged") }
    # Open or flagged: everything a "reviewed" mark has not cleared.
    scope :not_reviewed, -> { where(review_state: [ nil, "flagged" ]) }
  end

  class_methods do
    # The mark for a submitted state: "flagged", "reviewed", nil for "open",
    # or :invalid for anything else.
    def review_state_from_param(value)
      return nil if value == REVIEW_STATE_OPEN
      return value if REVIEW_STATES.include?(value)

      :invalid
    end

    # Sets the review mark on every transaction in the scope and touches
    # their entries, as a normal save would, so cached rows and totals
    # refresh. The scope must already be authorized by the caller.
    #
    # @param state [String, nil] "flagged", "reviewed", or nil to clear
    # @return [Integer] number of transactions changed
    def set_review_state!(scope, state, user:)
      raise ArgumentError, "unknown review state: #{state.inspect}" unless state.nil? || REVIEW_STATES.include?(state)

      transaction do
        ids = scope.unscope(:order, :select)
                   .where("transactions.review_state IS DISTINCT FROM ?", state)
                   .order(:id).lock("FOR UPDATE OF transactions").pluck(:id)
        next 0 if ids.empty?

        now = Time.current
        where(id: ids).update_all(
          review_state: state,
          review_state_changed_at: state && now,
          review_state_changed_by_id: state && user&.id,
          updated_at: now
        )
        Entry.where(entryable_type: "Transaction", entryable_id: ids).touch_all(time: now)

        ids.size
      end
    end

    # Review mark for one transaction that replaces several (an unsplit
    # parent): flagged wins, then reviewed when every source was reviewed,
    # otherwise open. The winning mark keeps its who and when.
    def combined_review_attributes(transactions)
      transactions = transactions.compact
      latest = ->(list) { list.max_by { |t| t.review_state_changed_at || Time.at(0) } }

      winner = latest.(transactions.select(&:review_flagged?))
      winner ||= latest.(transactions) if transactions.any? && transactions.all?(&:reviewed?)

      winner ? winner.review_attributes : { review_state: nil, review_state_changed_at: nil, review_state_changed_by_id: nil }
    end
  end

  def review_flagged?
    review_state == "flagged"
  end

  def reviewed?
    review_state == "reviewed"
  end

  # The mark this transaction takes over from one it replaces (a pending
  # transaction booked as this one): the other's mark when this one has none,
  # and flagged wins over reviewed. Empty when nothing changes.
  def review_attributes_taken_from(other)
    return {} unless other.is_a?(Transaction) && other.review_state.present?
    return {} if review_flagged? || (reviewed? && !other.review_flagged?)

    other.review_attributes
  end

  # The review attributes copied to a transaction that stands in for this
  # one (a split child).
  def review_attributes
    {
      review_state: review_state,
      review_state_changed_at: review_state_changed_at,
      review_state_changed_by_id: review_state_changed_by_id
    }
  end
end
