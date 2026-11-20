# Transfers, recurring series and imports can tie a moving account to
# records of the family it leaves. When User#transfer_to_family! moves
# accounts, each such link either follows the accounts into the new family or,
# when it also involves an account that stays behind, is undone so that neither
# family is left holding a record that reaches into the other.
class User::CrossFamilyLinks
  def initialize(accounts, new_family)
    @account_ids = accounts.map(&:id)
    @new_family = new_family
  end

  # Runs before the accounts change family, inside the caller's transaction.
  def resolve!
    return if account_ids.empty?

    detach_cross_family_transfers!
    move_recurring_transactions!
    move_imports!
  end

  private
    attr_reader :account_ids, :new_family

    def moving?(account_id)
      account_ids.include?(account_id)
    end

    def now
      @now ||= Time.current
    end

    def moving_entries
      Entry.where(account_id: account_ids).select(:id)
    end

    def moving_transactions
      Transaction.joins(:entry).where(entries: { account_id: account_ids }).select(:id)
    end

    # A transfer has to stay within one family, and neither family can see the
    # other side once the accounts split. Both legs survive as standalone
    # transactions. Fees are real charges on their accounts, so they are kept
    # too, and a fee on the other side of a transfer that stays whole leaves it.
    def detach_cross_family_transfers!
      transfer_ids = Transfer
        .where(inflow_transaction_id: moving_transactions)
        .or(Transfer.where(outflow_transaction_id: moving_transactions))
        .or(Transfer.where(id: Transaction.where(id: moving_transactions).where.not(transfer_id: nil).select(:transfer_id)))
        .select(:id)

      Transfer.where(id: transfer_ids)
        .includes(inflow_transaction: :entry, outflow_transaction: :entry, fee_transactions: :entry)
        .find_each do |transfer|
          legs_moving = moving?(transfer.outflow_transaction.entry.account_id)

          if moving?(transfer.inflow_transaction.entry.account_id) != legs_moving
            Transaction.where(id: transfer.fee_transactions.map(&:id)).update_all(transfer_id: nil, updated_at: now)
            transfer.fee_transactions.reset
            transfer.destroy!
          else
            other_side = transfer.fee_transactions.reject { |fee| moving?(fee.entry.account_id) == legs_moving }
            Transaction.where(id: other_side.map(&:id)).update_all(transfer_id: nil, updated_at: now) if other_side.any?
          end
        end

      # A rejected match between the two families can never be proposed again.
      RejectedTransfer
        .where(inflow_transaction_id: moving_transactions).where.not(outflow_transaction_id: moving_transactions)
        .or(RejectedTransfer.where(outflow_transaction_id: moving_transactions).where.not(inflow_transaction_id: moving_transactions))
        .delete_all
    end

    # A series whose accounts all move goes with them, occurrences included.
    # A recurring transfer between a moving and a remaining account cannot
    # live in either family and is removed, as it would be if one of its
    # accounts were deleted. Payments and price changes recorded against an
    # entry of the other family keep their record but lose the entry, as they
    # do when that entry is deleted.
    def move_recurring_transactions!
      moved_ids = []

      RecurringTransaction
        .where(account_id: account_ids)
        .or(RecurringTransaction.where(destination_account_id: account_ids))
        .where.not(family_id: new_family.id)
        .includes(:merchant)
        .find_each do |series|
          endpoints = [ series.account_id, series.destination_account_id ].compact

          if endpoints.all? { |account_id| moving?(account_id) }
            series.update_columns(family_id: new_family.id, updated_at: now, **foreign_classification(series))
            moved_ids << series.id
          else
            series.destroy!
          end
        end

      RecurringOccurrence.where(recurring_transaction_id: moved_ids).update_all(family_id: new_family.id, updated_at: now)
      release_cross_family_entries!(moved_ids)
    end

    # Category and family merchant belong to the old family. The series keeps
    # its merchant's name so it stays recognizable and valid without it.
    def foreign_classification(series)
      attrs = {}
      attrs[:category_id] = nil if series.category_id && !Category.where(id: series.category_id, family_id: new_family.id).exists?

      merchant = series.merchant
      if merchant.is_a?(FamilyMerchant) && merchant.family_id != new_family.id
        attrs[:merchant_id] = nil
        attrs[:name] = series.name.presence || merchant.name
      end

      attrs
    end

    def release_cross_family_entries!(moved_ids)
      cross_family_refs(RecurringAllocation.joins(:recurring_occurrence), "recurring_occurrences.recurring_transaction_id", moved_ids)
        .each { |scope| RecurringAllocation.where(id: scope.select(:id)).update_all(entry_id: nil, updated_at: now) }

      cross_family_refs(RecurringPriceChange.all, "recurring_price_changes.recurring_transaction_id", moved_ids)
        .each { |scope| scope.update_all(entry_id: nil, updated_at: now) }

      cross_family_refs(RecurringMatchRejection.all, "recurring_match_rejections.recurring_transaction_id", moved_ids)
        .each(&:delete_all)
    end

    # Rows of a moved series that point at an entry staying behind, and rows
    # of any other series that point at a moving entry.
    def cross_family_refs(scope, series_column, moved_ids)
      scope = scope.where.not(entry_id: nil)

      [
        scope.where(series_column => moved_ids).where.not(entry_id: moving_entries),
        scope.where.not(series_column => moved_ids).where(entry_id: moving_entries)
      ]
    end

    # Reverting an import destroys the accounts and entries it created. An
    # import left behind in the old family must therefore not reach records
    # that now belong to the new one: it either moves along with everything it
    # created, or lets go of the moving part.
    def move_imports!
      moving_statements = AccountStatement.where(account_id: account_ids).select(:id)

      imports = Import
        .where(id: Import.where(account_id: account_ids).select(:id))
        .or(Import.where(id: Import.where(account_statement_id: moving_statements).select(:id)))
        .or(Import.where(id: Account.where(id: account_ids).where.not(import_id: nil).select(:import_id)))
        .or(Import.where(id: Entry.where(account_id: account_ids).where.not(import_id: nil).select(:import_id)))
        .where.not(family_id: new_family.id)
        .includes(:account_statement)
        .to_a

      moving_imports, split_imports = imports.partition { |import| fully_moving?(import) }

      move_out_of_sessions!(moving_imports)
      clear_foreign_mappings!(moving_imports)
      split_imports.each { |import| release_moving_records!(import) }
    end

    def fully_moving?(import)
      statement_account_id = import.account_statement&.account_id

      (import.account_id.nil? || moving?(import.account_id)) &&
        (statement_account_id.nil? || moving?(statement_account_id)) &&
        !Account.where(import_id: import.id).where.not(id: account_ids).exists? &&
        !Entry.where(import_id: import.id).where.not(account_id: account_ids).exists?
    end

    # A session's source mappings point at records of the family it belongs
    # to (categories, rules, budgets), so the session stays where it is, and
    # imports.(import_session_id, family_id) requires a moving import to leave it.
    def move_out_of_sessions!(moving_imports)
      return if moving_imports.empty?

      Import.where(id: moving_imports.map(&:id))
        .update_all(family_id: new_family.id, import_session_id: nil, updated_at: now)
    end

    # A reverted import goes back to pending and can be published again with
    # its saved mappings. Mappings to the old family's categories, tags or
    # accounts are cleared, so publishing in the new family asks for them anew.
    def clear_foreign_mappings!(moving_imports)
      mappings = Import::Mapping.where(import_id: moving_imports.map(&:id)).where.not(mappable_id: nil)

      mappings.distinct.pluck(:mappable_type).each do |type|
        klass = type.safe_constantize
        next unless klass&.column_names&.include?("family_id")

        foreign = mappings.where(mappable_type: type).where.not(mappable_id: klass.where(family_id: new_family.id).select(:id))
        foreign = foreign.where.not(mappable_id: account_ids) if klass <= Account
        foreign.update_all(mappable_id: nil, mappable_type: nil, updated_at: now)
      end
    end

    def release_moving_records!(import)
      Account.where(id: account_ids, import_id: import.id).update_all(import_id: nil, updated_at: now)
      Entry.where(account_id: account_ids, import_id: import.id).update_all(import_id: nil, updated_at: now)

      detached = {}
      detached[:account_id] = nil if import.account_id && moving?(import.account_id)
      detached[:account_statement_id] = nil if import.account_statement && moving?(import.account_statement.account_id)
      import.update_columns(**detached, updated_at: now) if detached.any?
    end
end
