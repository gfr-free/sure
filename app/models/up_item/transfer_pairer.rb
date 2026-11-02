# Pairs the two legs of a money movement between two linked Up accounts into a
# Transfer, using the counterpart account Up reports on each leg
# (transactions.extra["up"]["transfer_account_id"]) instead of the amount/date
# heuristic in Family#auto_match_transfers!.
#
# A pair needs both legs to point at each other's account, with opposite amounts
# in the same currency within DATE_WINDOW days. Round-ups swept into a Saver have
# no such counterpart (the spending side is the purchase, which carries no
# transferAccount and a different amount), so they stay unpaired.
#
# Only legs imported since +imported_since+ are considered as a trigger, so a
# transfer the user unlinked is not paired again on the next sync; older history
# is left to the heuristic matcher as before. Existing transfers and rejected
# pairs are never touched.
class UpItem::TransferPairer
  DATE_WINDOW = 4

  attr_reader :up_item, :imported_since

  def initialize(up_item, imported_since:)
    @up_item = up_item
    @imported_since = imported_since
  end

  # @return [Integer] number of transfers created
  def pair!
    return 0 if family.auto_match_transfers_disabled?
    return 0 if up_ids_by_account_id.size < 2

    legs = unpaired_legs
    outflows, inflows = legs.partition { |leg| leg.amount.positive? }
    inflows = inflows.group_by { |leg| [ leg.account_id, leg.up_transfer_account_id, leg.currency, -leg.amount ] }
    rejected = rejected_pairs(legs)
    used_ids = Set.new
    created = 0

    outflows.sort_by(&:date).each do |outflow|
      key = [ account_id_for(outflow.up_transfer_account_id), up_ids_by_account_id[outflow.account_id], outflow.currency, outflow.amount ]
      inflow = Array(inflows[key])
        .reject { |leg| used_ids.include?(leg.entryable_id) }
        .reject { |leg| rejected.include?([ leg.entryable_id, outflow.entryable_id ]) }
        .select { |leg| (leg.date - outflow.date).abs <= DATE_WINDOW }
        .select { |leg| new_leg?(leg) || new_leg?(outflow) }
        .min_by { |leg| [ (leg.date - outflow.date).abs, leg.date ] }
      next unless inflow

      next unless create_transfer(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)

      used_ids << inflow.entryable_id
      created += 1
    end

    created
  end

  private

    def family
      up_item.family
    end

    # Sure account id => Up account id, for the item's linked, visible accounts.
    def up_ids_by_account_id
      @up_ids_by_account_id ||= up_item.up_accounts
        .joins(:account)
        .merge(Account.visible)
        .where.not(account_id: nil)
        .pluck("accounts.id", "up_accounts.account_id")
        .to_h
    end

    def account_id_for(up_account_id)
      @account_ids_by_up_id ||= up_ids_by_account_id.invert
      @account_ids_by_up_id[up_account_id]
    end

    # Settled, included Up legs on the item's linked accounts that name another
    # linked account as their counterpart and are not part of a transfer yet.
    def unpaired_legs
      Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: up_ids_by_account_id.keys, source: "up", excluded: false)
        .where("transactions.extra -> 'up' ->> 'transfer_account_id' IN (?)", up_ids_by_account_id.values)
        .where.not(amount: 0)
        .where.not(Transaction.pending_sql("transactions", providers: [ "up" ]))
        .where("NOT EXISTS (SELECT 1 FROM transfers WHERE transfers.inflow_transaction_id = transactions.id OR transfers.outflow_transaction_id = transactions.id)")
        .select("entries.*, transactions.extra -> 'up' ->> 'transfer_account_id' AS up_transfer_account_id")
        .to_a
    end

    def rejected_pairs(legs)
      ids = legs.map(&:entryable_id)
      return Set.new if ids.empty?

      RejectedTransfer
        .where(inflow_transaction_id: ids, outflow_transaction_id: ids)
        .pluck(:inflow_transaction_id, :outflow_transaction_id)
        .to_set
    end

    def new_leg?(leg)
      leg.created_at >= imported_since
    end

    # Up reports the movement itself, so the transfer is confirmed right away
    # and both legs take their transfer kinds (Transfer#confirm!). The savepoint
    # keeps the outer transaction usable when a concurrent sync paired either leg.
    def create_transfer(inflow_transaction_id:, outflow_transaction_id:)
      Transfer.transaction(requires_new: true) do
        transfer = Transfer.create!(inflow_transaction_id:, outflow_transaction_id:)
        transfer.confirm!
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    rescue ActiveRecord::RecordInvalid => e
      raise unless %i[inflow_transaction_id outflow_transaction_id].any? { |attr| e.record.errors.of_kind?(attr, :taken) }

      false
    end
end
