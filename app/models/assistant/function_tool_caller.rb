class Assistant::FunctionToolCaller
  Error = Class.new(StandardError)
  FunctionExecutionError = Class.new(Error)

  attr_reader :functions

  # With a user, budget and plan tools are checked against the family's
  # current switches on every call, since a chat response keeps the tool list
  # it was built with while an admin may turn either feature off mid-response.
  def initialize(functions = [], user: nil)
    @functions = functions
    @user = user
  end

  def fulfill_requests(function_requests)
    function_requests.map do |function_request|
      result = execute(function_request)

      ToolCall::Function.from_function_request(function_request, result)
    end
  end

  def function_definitions
    functions.map(&:to_definition)
  end

  private
    # Tool failures come back as data instead of raising, so one bad call no
    # longer aborts the whole turn. The hint steers the model toward a single
    # corrected retry (the system prompt pairs it with a retry-once rule).
    def execute(function_request)
      fn = find_function(function_request)

      if fn.nil?
        return {
          error: "Unknown tool: #{function_request.function_name}",
          hint: "Only call tools from the provided list."
        }
      end

      fn_args = JSON.parse(function_request.function_args.presence || "{}")
      fn.call(fn_args)
    rescue JSON::ParserError => e
      Rails.logger.warn("Assistant tool #{function_request.function_name} got invalid JSON arguments: #{e.class}: #{e.message}")

      {
        error: "Arguments were not valid JSON",
        hint: "Re-send #{function_request.function_name} with valid JSON arguments."
      }
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.warn("Assistant tool #{function_request.function_name} raised #{e.class}: #{e.message}")

      # The raised message carries the scoped relation's full SQL, so returning
      # it verbatim handed any caller the access-control schema: the tables, the
      # owner/share join, the lot. MCP passes this straight through to an
      # external client, which needs only a guessed UUID to read it. The message
      # says nothing the caller can act on that the hint does not, and a
      # not-found is deliberately indistinguishable from a forbidden id.
      {
        error: "No such record, or it is not one you have access to",
        hint: "That record was not found. List valid options first (for example get_accounts or get_categories) and retry once with an exact match."
      }
    rescue Date::Error, ArgumentError, KeyError => e
      Rails.logger.warn("Assistant tool #{function_request.function_name} raised #{e.class}: #{e.message}")

      {
        error: e.message,
        hint: "Check argument formats (dates are YYYY-MM-DD) and retry once with corrected arguments."
      }
    rescue => e
      Rails.logger.error("Assistant tool #{fn.name} failed: #{e.class}: #{e.message}")

      {
        error: "#{fn.name} failed unexpectedly",
        hint: "Do not retry with the same arguments. Answer with the data you already have and note the gap."
      }
    end

    def find_function(function_request)
      fn = functions.find { |f| f.name == function_request.function_name }
      fn if fn && !switched_off?(fn)
    end

    def switched_off?(fn)
      return false if @user.nil?

      budget_tool = Assistant::BUDGET_FUNCTION_CLASSES.include?(fn.class)
      plan_tool = Assistant::PLAN_FUNCTION_CLASSES.include?(fn.class)
      return false unless budget_tool || plan_tool

      # Uncached: the response job's query cache may still hold the switches
      # from before an admin changed them in another process.
      budgets_enabled, plan_enabled = Family.uncached do
        Family.where(id: @user.family_id).pick(:budgets_enabled, :plan_enabled)
      end
      (budget_tool && budgets_enabled == false) || (plan_tool && plan_enabled == false)
    end
end
