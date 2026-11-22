class AddInvoiceDetailsToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :invoice_number, :string, limit: 100
    add_column :receipts, :due_date, :date
    add_column :receipts, :tax_amount, :decimal, precision: 19, scale: 4
  end
end
