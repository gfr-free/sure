# frozen_string_literal: true

class AddApplyImmediatelyToRules < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:rules, :apply_immediately)

    add_column :rules, :apply_immediately, :boolean, null: false, default: false
  end
end
