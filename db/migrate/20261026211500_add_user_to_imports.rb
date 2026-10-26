class AddUserToImports < ActiveRecord::Migration[8.1]
  def change
    add_reference :imports, :user, type: :uuid, null: true, index: true, foreign_key: { on_delete: :nullify }
  end
end
