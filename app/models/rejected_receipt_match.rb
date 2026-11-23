# A receipt-transaction pair the uploader said does not belong together, so the
# automatic matching never suggests it again.
class RejectedReceiptMatch < ApplicationRecord
  belongs_to :receipt
  belongs_to :rejected_transaction, class_name: "Transaction", foreign_key: :transaction_id
end
