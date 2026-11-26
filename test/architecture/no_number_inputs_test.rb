# frozen_string_literal: true

require "test_helper"

# A number input drops a comma decimal in Chromium ("12,50" is lost, or read
# as 1250), so an amount uses money_field and any other decimal (a quantity,
# a rate) uses decimal_field. Only a whole number, where a comma cannot mean
# a decimal point, may stay a number input, and is listed here with why.
class NoNumberInputsTest < ActiveSupport::TestCase
  WHOLE_NUMBER_FIELDS = {
    "app/views/goals/_form.html.erb" => { "target_months" => "months to reach a goal" },
    "app/views/import/configurations/_transaction_import.html.erb" => { "rows_to_skip" => "a row count" },
    "app/views/loans/_form.html.erb" => { "term_months" => "a loan term in months" },
    "app/views/properties/_form.html.erb" => {
      "year_built" => "a year",
      "area_value" => "an integer column (properties.area_value)"
    },
    "app/views/properties/_overview_fields.html.erb" => {
      "year_built" => "a year",
      "area_value" => "an integer column (properties.area_value)"
    },
    "app/views/recurring_transactions/_form.html.erb" => {
      "frequency_interval" => "every N days, weeks or months",
      "end_after_count" => "an occurrence count"
    },
    "app/views/settings/hostings/_llm_provider_selector.html.erb" => { "llm_max_items_per_call" => "an item count" },
    "app/views/settings/hostings/_openai_settings.html.erb" => {
      "llm_context_window" => "a token count",
      "llm_max_response_tokens" => "a token count",
      "openai_request_timeout" => "whole seconds",
      "ai_response_timeout" => "whole seconds",
      "ai_health_probe_timeout" => "whole seconds"
    },
    "app/views/settings/hostings/_page_cache_setting.html.erb" => { "name" => "whole seconds or entries per cache setting" },
    "app/views/sharesight_accounts/_settings_fields.html.erb" => { "settlement_window_days" => "a day count" },
    "app/views/vehicles/_form.html.erb" => {
      "year" => "a year",
      "mileage_value" => "an integer column (vehicles.mileage_value)"
    }
  }.freeze

  NUMBER_FIELD_CALL = /\bnumber_field(?:_tag)?[\s(]+["':]?([\w\[\]#{}]+)/
  NUMBER_TYPE = /type(?::\s*|\s*=\s*)["':]?number\b/
  DECIMAL_INPUTMODE = /inputmode(?::\s*|\s*=\s*|"\s*=>\s*)["':]?decimal\b/
  MONEY_FIELD = "app/views/shared/_money_field.html.erb"

  test "only whole numbers use a number input" do
    unexpected = number_inputs.reject do |path, field|
      WHOLE_NUMBER_FIELDS.dig(path, field)
    end

    assert_empty unexpected.map { |path, field| "#{path}: #{field}" }, <<~MESSAGE
      A number input drops a comma decimal in Chromium. Use form.money_field
      for an amount or form.decimal_field for any other decimal (a quantity,
      a rate, a share). A whole number may stay a number_field: list it in
      WHOLE_NUMBER_FIELDS in #{__FILE__} with the reason.
    MESSAGE
  end

  test "every listed whole-number field still exists" do
    found = number_inputs.to_set
    stale = WHOLE_NUMBER_FIELDS.flat_map { |path, fields| fields.keys.map { |field| [ path, field ] } }
                               .reject { |entry| found.include?(entry) }

    assert_empty stale.map { |path, field| "#{path}: #{field}" }, "remove these from WHOLE_NUMBER_FIELDS"
  end

  # A hand-built decimal text input skips the money field's reading of a
  # comma, an expression and the currency's precision, and what it submits.
  test "only the money field builds a decimal text input" do
    hand_built = view_files.flat_map do |path, lines|
      lines.filter_map do |line|
        next if comment?(line) || path == MONEY_FIELD

        path if line.match?(DECIMAL_INPUTMODE)
      end
    end

    assert_empty hand_built.uniq, "use form.money_field or form.decimal_field instead of inputmode: \"decimal\""
  end

  private
    def view_files
      Dir[Rails.root.join("app/{views,components}/**/*.{erb,rb}")].map do |file|
        [ Pathname(file).relative_path_from(Rails.root).to_s, File.read(file).lines ]
      end
    end

    def comment?(line)
      line.lstrip.start_with?("#", "<%#")
    end

    def number_inputs
      view_files.flat_map do |path, lines|
        lines.filter_map do |line|
          next if comment?(line)

          if (match = line.match(NUMBER_FIELD_CALL))
            [ path, match[1] ]
          elsif line.match?(NUMBER_TYPE) && !line.include?("data-requirement-type")
            [ path, "type number" ]
          end
        end
      end
    end
end
