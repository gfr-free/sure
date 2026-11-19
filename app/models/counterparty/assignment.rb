# Assigns a transaction (or one part of a split) to a person: the entry
# becomes one leg of a confirmed transfer whose other leg sits on the
# person's clearing account. An outflow the user paid for someone raises
# what they owe; an inflow from them (a payback) lowers it. Either way the
# entry leaves the budget, as transfers to an asset account do.
class Counterparty::Assignment
  NotAssignable = Class.new(StandardError)

  attr_reader :entry

  # The other leg of the entry's confirmed transfer when that leg sits on a
  # clearing account. Nil for entries on a clearing account themselves.
  def self.clearing_leg_for(entry)
    transaction = entry.entryable
    return nil unless transaction.is_a?(Transaction)
    return nil if entry.account.nil? || entry.account.clearing?

    transfer = transaction.transfer
    return nil unless transfer&.confirmed?

    other = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction : transfer.inflow_transaction
    other_entry = other&.entry
    other_entry if other_entry&.account&.clearing?
  end

  def initialize(entry)
    @entry = entry
  end

  def counterparty
    clearing_leg&.account&.clearing&.counterparty
  end

  def assignable?
    transaction = entry.entryable
    transaction.is_a?(Transaction) &&
      !entry.account.clearing? &&
      !entry.split_parent? &&
      !entry.excluded? &&
      !entry.amount.zero? &&
      !transaction.pending? &&
      (transaction.transfer.nil? || clearing_leg.present?)
  end

  # Moves the entry to `counterparty`, or releases it when nil. Returns the
  # clearing leg, or nil once released.
  def update!(counterparty, user:)
    return unassign! if counterparty.nil?
    return clearing_leg if self.counterparty == counterparty

    raise NotAssignable unless assignable?
    raise ArgumentError, "person belongs to another family" unless counterparty.family_id == entry.account.family_id

    previous_account = clearing_leg&.account

    Transfer.transaction do
      release_clearing_leg
      account = counterparty.clearing_account_for!(entry.currency, user: user)
      counterpart = account.entries.build(
        amount: -entry.amount,
        currency: entry.currency,
        date: entry.date,
        name: entry.name,
        user_modified: true,
        entryable: Transaction.new
      )

      transfer = Transfer.new(
        inflow_transaction: entry.amount.positive? ? counterpart.transaction : entry.transaction,
        outflow_transaction: entry.amount.positive? ? entry.transaction : counterpart.transaction,
        status: "confirmed"
      )
      transfer.save!
      transfer.confirm!
      # A leg older than the account's zero opening anchor would not count.
      account.ensure_opening_anchor_precedes_entries
      @clearing_leg = counterpart
    end

    sync_accounts_later(entry.account, previous_account, @clearing_leg.account)
    @clearing_leg
  end

  def unassign!
    clearing_account = clearing_leg&.account
    return nil unless clearing_account

    Transfer.transaction { release_clearing_leg }
    sync_accounts_later(entry.account, clearing_account)
    nil
  end

  private
    def clearing_leg
      return @clearing_leg if defined?(@clearing_leg)

      @clearing_leg = self.class.clearing_leg_for(entry)
    end

    # Deleting the clearing leg destroys the transfer, which gives the entry
    # back its standalone kind (Transfer#release_transactions).
    def release_clearing_leg
      leg = clearing_leg
      return unless leg

      leg.destroy!
      @clearing_leg = nil
      entry.reload
    end

    def sync_accounts_later(*accounts)
      accounts.compact.uniq.each { |account| account.sync_later(window_start_date: entry.date) }
    end
end
