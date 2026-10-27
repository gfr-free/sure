require "test_helper"

class Assistant::FunctionToolCallerTest < ActiveSupport::TestCase
  # Minimal stub function that echoes back whatever args it receives.
  class EchoFunction < Assistant::Function
    def self.name = "echo"
    def self.description = "Echoes the received arguments"
    def call(params = {}) = params
  end

  FunctionRequest = Provider::LlmConcept::ChatFunctionRequest

  setup do
    @caller = Assistant::FunctionToolCaller.new([ EchoFunction.new(nil) ])
  end

  test "parses JSON arguments and forwards them to the function" do
    request = FunctionRequest.new(
      id: "call_1", call_id: "call_1", function_name: "echo",
      function_args: { "foo" => "bar" }.to_json
    )

    result = @caller.fulfill_requests([ request ]).first

    assert_equal({ "foo" => "bar" }, result.function_result)
  end

  test "treats empty-string arguments as an empty argument set" do
    request = FunctionRequest.new(
      id: "call_2", call_id: "call_2", function_name: "echo",
      function_args: ""
    )

    # Regression for #2722: JSON.parse("") used to raise, killing the turn.
    result = assert_nothing_raised do
      @caller.fulfill_requests([ request ]).first
    end

    assert_equal({}, result.function_result)
  end

  test "treats nil arguments as an empty argument set" do
    request = FunctionRequest.new(
      id: "call_3", call_id: "call_3", function_name: "echo",
      function_args: nil
    )

    result = assert_nothing_raised do
      @caller.fulfill_requests([ request ]).first
    end

    assert_equal({}, result.function_result)
  end

  test "unknown tool returns an error result instead of raising" do
    request = FunctionRequest.new(
      id: "call_4", call_id: "call_4", function_name: "does_not_exist",
      function_args: "{}"
    )

    result = assert_nothing_raised do
      @caller.fulfill_requests([ request ]).first
    end

    assert_equal "Unknown tool: does_not_exist", result.function_result["error"]
    assert_includes result.function_result["hint"], "provided list"
  end

  test "invalid JSON arguments return an error result with a hint" do
    request = FunctionRequest.new(
      id: "call_5", call_id: "call_5", function_name: "echo",
      function_args: "{not json"
    )

    result = @caller.fulfill_requests([ request ]).first

    assert_equal "Arguments were not valid JSON", result.function_result["error"]
    assert_includes result.function_result["hint"], "echo"
  end

  test "missing records return an error result steering a corrected retry" do
    caller = Assistant::FunctionToolCaller.new([ NotFoundFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_6", call_id: "call_6", function_name: "not_found",
      function_args: "{}"
    )

    result = caller.fulfill_requests([ request ]).first

    assert_includes result.function_result["hint"], "retry once"
  end

  test "date and argument errors return an error result with a format hint" do
    caller = Assistant::FunctionToolCaller.new([ BadDateFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_7", call_id: "call_7", function_name: "bad_date",
      function_args: "{}"
    )

    result = caller.fulfill_requests([ request ]).first

    assert_includes result.function_result["hint"], "YYYY-MM-DD"
  end

  test "unexpected failures return a do-not-retry error result" do
    caller = Assistant::FunctionToolCaller.new([ ExplodingFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_8", call_id: "call_8", function_name: "exploding",
      function_args: "{}"
    )

    result = assert_nothing_raised do
      caller.fulfill_requests([ request ]).first
    end

    assert_equal "exploding failed unexpectedly", result.function_result["error"]
    assert_includes result.function_result["hint"], "Do not retry"
  end

  test "array arguments sent as a JSON-encoded string are decoded before the call" do
    caller = Assistant::FunctionToolCaller.new([ ArrayEchoFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_9", call_id: "call_9", function_name: "array_echo",
      function_args: { "names" => "[\"Food\", \"Rent\"]", "label" => "[not an array]" }.to_json
    )

    result = caller.fulfill_requests([ request ]).first

    assert_equal [ "Food", "Rent" ], result.function_result["names"]
    assert_equal "[not an array]", result.function_result["label"], "Non-array params stay untouched"
  end

  test "a bare string for an array argument is wrapped into a one-element array" do
    caller = Assistant::FunctionToolCaller.new([ ArrayEchoFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_10", call_id: "call_10", function_name: "array_echo",
      function_args: { "names" => "Food" }.to_json
    )

    result = caller.fulfill_requests([ request ]).first

    assert_equal [ "Food" ], result.function_result["names"]
  end

  test "a JSON-encoded single value for an array argument is wrapped" do
    caller = Assistant::FunctionToolCaller.new([ ArrayEchoFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_12", call_id: "call_12", function_name: "array_echo",
      function_args: { "names" => "\"Food\"" }.to_json
    )

    result = caller.fulfill_requests([ request ]).first

    assert_equal [ "Food" ], result.function_result["names"]
  end

  test "blank strings and JSON null for an array argument are passed through unchanged" do
    caller = Assistant::FunctionToolCaller.new([ ArrayEchoFunction.new(nil) ])

    [ "", "  ", "null" ].each_with_index do |raw, i|
      request = FunctionRequest.new(
        id: "call_blank_#{i}", call_id: "call_blank_#{i}", function_name: "array_echo",
        function_args: { "names" => raw }.to_json
      )

      result = caller.fulfill_requests([ request ]).first

      assert_equal raw, result.function_result["names"], "#{raw.inspect} must not become an empty list"
    end
  end

  test "get_transactions filters by categories sent as a JSON-encoded string" do
    user = users(:family_admin)
    caller = Assistant::FunctionToolCaller.new([ Assistant::Function::GetTransactions.new(user) ])
    request = FunctionRequest.new(
      id: "call_11", call_id: "call_11", function_name: "get_transactions",
      function_args: { "categories" => [ categories(:food_and_drink).name ].to_json }.to_json
    )

    result = caller.fulfill_requests([ request ]).first.function_result

    assert_nil result["error"], "Expected transactions, got: #{result.inspect}"
    assert_includes result["transactions"].map { |t| t["id"] }, transactions(:one).id
    assert result["transactions"].all? { |t| t["category"] == categories(:food_and_drink).name }
  end

  class ArrayEchoFunction < Assistant::Function
    def self.name = "array_echo"
    def self.description = "Echoes arguments; declares an array param"
    def call(params = {}) = params

    def params_schema
      build_schema(properties: {
        names: { type: "array", items: { type: "string" } },
        label: { type: "string" }
      })
    end
  end

  class NotFoundFunction < Assistant::Function
    def self.name = "not_found"
    def self.description = "Always raises RecordNotFound"
    def call(params = {}) = raise(ActiveRecord::RecordNotFound, "Couldn't find Account")
  end

  class BadDateFunction < Assistant::Function
    def self.name = "bad_date"
    def self.description = "Always raises a date parse error"
    def call(params = {}) = Date.parse("not-a-date")
  end

  class ExplodingFunction < Assistant::Function
    def self.name = "exploding"
    def self.description = "Always raises an unexpected error"
    def call(params = {}) = raise(NoMethodError, "boom")
  end
end
