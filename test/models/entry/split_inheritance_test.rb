require "test_helper"

# Split parts must stay the same money as their parent. These tests make every
# new column or extra key take a side in Entry::SplitInheritance.
class Entry::SplitInheritanceTest < ActiveSupport::TestCase
  test "every entries column is in exactly one group" do
    assert_grouped Entry.column_names, Entry::SplitInheritance::ENTRY_COLUMNS
  end

  test "every transactions column is in exactly one group" do
    assert_grouped Transaction.column_names, Entry::SplitInheritance::TRANSACTION_COLUMNS
  end

  test "every key the app reads from an extra hash is in exactly one group" do
    pattern = /\bextra(?:&?\.(?:dig|fetch|key\?|has_key\?)\(|\[)\s*["':]([A-Za-z_]+)/
    keys = Dir[Rails.root.join("{app,lib}/**/*.rb")].flat_map { |path| File.read(path).scan(pattern).flatten }.uniq

    assert_grouped keys, Entry::SplitInheritance::EXTRA_KEYS, stale_check: false
  end

  private
    def assert_grouped(names, groups, stale_check: true)
      grouped = groups.values.flatten

      assert_equal grouped.uniq.sort, grouped.sort, "A name is in more than one group of Entry::SplitInheritance"
      assert_empty names - grouped,
        "Decide in Entry::SplitInheritance whether split parts take these from their parent: #{(names - grouped).join(', ')}"
      assert_empty grouped - names, "Entry::SplitInheritance lists names that no longer exist: #{(grouped - names).join(', ')}" if stale_check
    end
end
