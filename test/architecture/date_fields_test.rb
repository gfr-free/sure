# frozen_string_literal: true

require "test_helper"

# Every form that edits an entry's date goes through
# StyledFormBuilder#entry_date_field, so all of them share the same lower
# bound (the day after Entry.min_supported_date, which the model rejects)
# and the same default. Sync start dates lie in the past by definition, so
# each of those inputs carries a max.
class DateFieldsTest < ActiveSupport::TestCase
  # Form attributes that become an Entry's date.
  ENTRY_DATE_ATTRIBUTES = %w[date opening_balance_date paid_on].freeze

  DATE_INPUT = /\bdate_field(?:_tag)?\b|type=["']date["']/
  ENTRY_DATE_FIELD = /\A\s*date_field\s*\(?\s*:(#{ENTRY_DATE_ATTRIBUTES.join("|")})\b/

  test "entry dates use entry_date_field" do
    offenders = date_input_statements.filter_map do |path, number, statement|
      "#{path}:#{number}" if statement.match?(ENTRY_DATE_FIELD)
    end

    assert_empty offenders, <<~MESSAGE
      Use form.entry_date_field for an entry's date. It sets the lowest date
      the model accepts and the default; pass past_only: true where a future
      date makes no sense, or value: nil where blank means "unchanged".
    MESSAGE
  end

  test "sync start date inputs cannot pick a future day" do
    offenders = date_input_statements.filter_map do |path, number, statement|
      next unless statement.include?("sync_start_date")
      next if statement.match?(/\bmax[:=]/)

      "#{path}:#{number}"
    end

    assert_empty offenders, "Give every sync start date input max: Date.current (a sync cannot start in the future)."
  end

  private
    # Each date input from its helper name or type attribute to the end of its
    # ERB call or tag, so options on the following lines are seen as well.
    def date_input_statements
      Dir[Rails.root.join("app/{views,components}/**/*.erb")].sort.flat_map do |file|
        path = Pathname(file).relative_path_from(Rails.root).to_s
        source = File.read(file).gsub(/<%#.*?%>/m) { |comment| "\n" * comment.count("\n") }
        lines = source.lines

        lines.each_with_index.filter_map do |line, index|
          next unless (start = line.index(DATE_INPUT))

          rest = lines[index..].join[start..]
          statement =
            if rest.start_with?("type")
              # A raw <input>: drop ERB inside its attributes, then stop at ">".
              rest.gsub(/<%=?.*?%>/m, "erb").split(">", 2).first
            else
              rest.split("%>", 2).first
            end
          [ path, index + 1, statement ]
        end
      end
    end
end
