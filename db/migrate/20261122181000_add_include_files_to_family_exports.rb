class AddIncludeFilesToFamilyExports < ActiveRecord::Migration[8.1]
  def change
    add_column :family_exports, :include_files, :boolean, default: false, null: false
  end
end
