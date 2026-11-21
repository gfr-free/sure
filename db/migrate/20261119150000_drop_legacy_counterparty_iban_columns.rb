# Production only. The IBAN rework keeps just the last four characters of a
# counterparty's IBAN or account reference. Production still holds the full
# values in the columns of the earlier version, plus unique IBAN indexes that
# the rework dropped. Carry the last four characters over, then remove both.
class DropLegacyCounterpartyIbanColumns < ActiveRecord::Migration[8.1]
  LEGACY_COLUMNS = %i[counterparty_iban counterparty_account_id].freeze
  LEGACY_INDEXES = {
    accounts: "index_accounts_on_family_id_and_iban_and_currency",
    merchants: %w[index_merchants_on_family_id_and_iban index_merchants_on_source_and_iban]
  }.freeze

  class LegacyTransaction < ActiveRecord::Base
    self.table_name = "transactions"

    if ActiveRecordEncryptionConfig.ready?
      encrypts :counterparty_iban, deterministic: true
      encrypts :counterparty_account_id, deterministic: true
    end
  end

  def up
    carry_over_last4 if LEGACY_COLUMNS.all? { |column| column_exists?(:transactions, column) }

    LEGACY_COLUMNS.each { |column| remove_column :transactions, column, if_exists: true }
    LEGACY_INDEXES.each do |table, names|
      Array(names).each { |name| remove_index table, name: name, if_exists: true }
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private
    def carry_over_last4
      LegacyTransaction.reset_column_information
      LegacyTransaction.where.not(counterparty_iban: nil).or(LegacyTransaction.where.not(counterparty_account_id: nil)).find_each do |transaction|
        updates = {}
        iban = read_legacy(transaction, :counterparty_iban).to_s.gsub(/[^A-Za-z0-9]/, "").upcase
        reference = read_legacy(transaction, :counterparty_account_id).to_s.strip
        updates[:counterparty_iban_last4] = iban.last(4) if iban.present? && transaction.counterparty_iban_last4.nil?
        updates[:counterparty_reference_last4] = reference.last(4) if reference.present? && transaction.counterparty_reference_last4.nil?
        LegacyTransaction.where(id: transaction.id).update_all(updates) if updates.any?
      end
    end

    # A value that no longer decrypts (rotated keys) has no last four
    # characters to keep; the next sync fills them from the bank again.
    def read_legacy(transaction, attribute)
      transaction.public_send(attribute)
    rescue ActiveRecord::Encryption::Errors::Decryption
      nil
    end
end
