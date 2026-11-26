# frozen_string_literal: true

require "test_helper"

# Every form that edits an entry's date goes through
# StyledFormBuilder#entry_date_field, so all of them share the same lower
# bound (the day after Entry.min_supported_date, which the model rejects)
# and the same default. Sync start dates lie in the past by definition, so
# each of those inputs carries a max.
class DateFieldsTest < ActiveSupport::TestCase
  ENTRY_DATE_FIELD = /\bdate_field\s*\(?\s*:date\b/
  SYNC_START_DATE = /sync_start_date/
  DATE_INPUT = /\bdate_field(?:_tag)?\b|type=["']date["']/

  test "entry dates use entry_date_field" do
    offenders = view_lines.filter_map do |path, number, line|
      "#{path}:#{number}" if line.match?(ENTRY_DATE_FIELD)
    end

    assert_empty offenders, <<~MESSAGE
      Use form.entry_date_field :date for an entry's date. It sets the lowest
      date the model accepts and the default; pass past_only: true where a
      future date makes no sense, or value: nil where blank means "unchanged".
    MESSAGE
  end

  test "sync start date inputs cannot pick a future day" do
    offenders = date_input_statements.filter_map do |path, number, statement|
      next unless statement.match?(SYNC_START_DATE)
      next if statement.match?(/\bmax[:=]/)

      "#{path}:#{number}"
    end

    assert_empty offenders, "Give every sync start date input max: Date.current (a sync cannot start in the future)."
  end

  private
    def view_files
      Dir[Rails.root.join("app/{views,components}/**/*.erb")].sort
    end

    def view_lines
      view_files.flat_map do |file|
        path = Pathname(file).relative_path_from(Rails.root).to_s
        File.readlines(file).each_with_index.filter_map do |line, index|
          next if line.lstrip.start_with?("<%#")

          [ path, index + 1, line ]
        end
      end
    end

    # A date input with the attributes up to the end of its tag or ERB call,
    # so options on the following lines are seen as well.
    def date_input_statements
      view_files.flat_map do |file|
        path = Pathname(file).relative_path_from(Rails.root).to_s
        lines = File.readlines(file)
        lines.each_with_index.filter_map do |line, index|
          next unless line.match?(DATE_INPUT)

          rest = lines[index..].join[line.index(DATE_INPUT)..]
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
