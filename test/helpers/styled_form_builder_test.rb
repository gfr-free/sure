require "test_helper"

class StyledFormBuilderTest < ActionView::TestCase
  include ApplicationHelper
  setup do
    @builder = StyledFormBuilder.new(:account_statement, nil, self, {})
  end

  test "a labelled file field sits in a form field with its label" do
    field = Nokogiri::HTML.fragment(@builder.file_field(:files, label: "Statement files")).at(".form-field")

    assert field, "expected the file input wrapped in a .form-field"
    assert_equal "account_statement_files", field.at("label.form-field__label")["for"]
    assert_includes field.at("input[type=file]")["class"].split, "file:bg-container-inset"
  end

  # text-destructive inverts in dark mode; a raw palette class does not.
  test "a required field marks its label with the destructive token" do
    field = Nokogiri::HTML.fragment(@builder.text_field(:name, label: "Name", required: true))
    marker = field.at("label.form-field__label span")

    assert marker, "expected a required marker in the label"
    assert_equal "*", marker.text
    assert_includes marker["class"].split, "text-destructive"
  end

  # The dropzones pass `hidden` and draw their own target: no wrapper, and
  # their classes merged in rather than replaced.
  test "an unlabelled file field comes back bare and keeps the caller's classes" do
    fragment = Nokogiri::HTML.fragment(@builder.file_field(:files, class: "hidden"))

    assert_nil fragment.at(".form-field")
    assert_includes fragment.at("input[type=file]")["class"].split, "hidden"
  end

  # Shown with the step's decimals, as blur would normalize it, so leaving
  # an auto-submitting field unedited does not save it.
  test "a decimal field is a money field without symbol or currency, shown with its step's decimals" do
    builder = StyledFormBuilder.new(:family, nil, self, {})
    field = Nokogiri::HTML.fragment(builder.decimal_field(:threshold, label: "Threshold", value: 0.8, in: 0..1, step: 0.05, auto_submit: true))
    container = field.at("[data-controller='money-field']")
    input = field.at("input[name='family[threshold]']")

    assert_equal "text", input["type"]
    assert_equal "decimal", input["inputmode"]
    assert_equal "0.80", input["value"]
    assert_equal "0", container["data-money-field-min-value"]
    assert_equal "1", container["data-money-field-max-value"]
    assert_equal "change", input["data-autosubmit-trigger-event"]
    assert_nil field.at("select")
    assert_includes field.at("[data-money-field-target='symbol']")["class"].split, "hidden"
  end

  test "a decimal field without a step keeps every decimal of the value" do
    builder = StyledFormBuilder.new(:trade, nil, self, {})
    field = Nokogiri::HTML.fragment(builder.decimal_field(:qty, label: "Quantity", value: 0.000063))

    assert_equal "0.000063", field.at("input[name='trade[qty]']")["value"]
    assert_equal "any", field.at("input[name='trade[qty]']")["step"]
  end
end
