# When a contract can end and by when notice has to go out for that.
#
# Terms end on the day before the next term starts: a policy whose main due
# date is 1 January ends on 31 December, and "3 months to the end of the term"
# means notice must arrive by 30 September. Notice given on a day counts that
# day, so the last day to give notice is the day before the notice period
# reaches back from the end.
#
#   end_of_term   the contract ends at a term boundary (minimum term, then
#                 every renewal period, anchored on the main due date when set)
#   end_of_month  notice runs to the end of a calendar month
#   any_day       notice runs from the day it is given
#
# Without a renewal period, a contract that is past its minimum term runs on
# indefinitely and can be ended with its notice period at any time (the German
# rule for consumer contracts since March 2022), so it has no deadline to miss.
class Contract::NoticeSchedule
  Result = Data.define(:term_ends_on, :notice_deadline, :earliest_end_on)

  MAX_BOUNDARIES = 600

  def initialize(contract, today: Date.current)
    @contract = contract
    @today = today
  end

  def call
    return Result.new(term_ends_on: contract.ends_on, notice_deadline: nil, earliest_end_on: nil) unless contract.active?
    return Result.new(term_ends_on: contract.ends_on, notice_deadline: nil, earliest_end_on: contract.ends_on) if fixed_end?

    case anchor
    when "any_day" then any_day
    when "end_of_month" then end_of_month
    else end_of_term
    end
  end

  # The last day notice can be given for the contract to end on `end_date`.
  def notice_before(end_date)
    return if notice_value.nil?

    case contract.notice_period_unit
    when "months" then (end_date + 1).advance(months: -notice_value) - 1
    when "weeks" then end_date - (notice_value * 7)
    else end_date - notice_value
    end
  end

  # The earliest end date when notice is given on `date`.
  def end_after_notice(date)
    return date if notice_value.nil?

    case contract.notice_period_unit
    when "months" then (date + 1).advance(months: notice_value) - 1
    when "weeks" then date + (notice_value * 7)
    else date + notice_value
    end
  end

  private
    attr_reader :contract, :today

    # A contract with a recorded end and nothing that renews it simply ends.
    def fixed_end?
      contract.ends_on.present? && contract.renewal_period_months.blank?
    end

    def notice_value
      contract.notice_period_value if contract.notice_period_unit.present?
    end

    # Without a stated anchor, a contract with terms ends at a term boundary;
    # one without terms can end whenever its notice runs out.
    def anchor
      return contract.notice_anchor if contract.notice_anchor.present?

      terms? ? "end_of_term" : "any_day"
    end

    def terms?
      minimum_term_end.present? || (contract.renewal_period_months.present? && term_start.present?)
    end

    def term_start
      contract.started_on
    end

    def minimum_term_end
      return if term_start.nil? || contract.minimum_term_months.to_i.zero?

      term_start.advance(months: contract.minimum_term_months) - 1
    end

    # Notice given before the minimum term runs out can only end the contract
    # when it does; the deadline is the last day to catch that end.
    def minimum_term_deadline
      term_end = minimum_term_end
      return if term_end.nil?

      deadline = notice_before(term_end)
      return if deadline.nil? || deadline < today

      Result.new(term_ends_on: term_end, notice_deadline: deadline, earliest_end_on: term_end)
    end

    def any_day
      minimum_term_deadline ||
        Result.new(term_ends_on: nil, notice_deadline: nil, earliest_end_on: [ end_after_notice(today), minimum_term_end ].compact.max)
    end

    def end_of_month
      minimum_term_deadline ||
        Result.new(term_ends_on: nil, notice_deadline: nil,
                   earliest_end_on: [ end_after_notice(today).end_of_month, minimum_term_end ].compact.max)
    end

    def end_of_term
      renewal = contract.renewal_period_months
      return any_day if renewal.blank?

      boundaries.each do |term_end|
        deadline = notice_before(term_end)

        if deadline.nil?
          return Result.new(term_ends_on: term_end, notice_deadline: nil, earliest_end_on: nil) if term_end >= today
        elsif deadline >= today
          return Result.new(term_ends_on: term_end, notice_deadline: deadline, earliest_end_on: term_end)
        end
      end

      Result.new(term_ends_on: nil, notice_deadline: nil, earliest_end_on: nil)
    end

    # Term ends from the first one after the minimum term onwards. The main due
    # date, when recorded, fixes the grid (the day after each term end); the
    # start date does otherwise.
    def boundaries
      renewal = contract.renewal_period_months
      first_allowed = minimum_term_end || today

      grid_start = contract.renewal_anchor_on || term_start
      return [] if grid_start.nil?

      # Walk back to the first grid point, then forward past the minimum term.
      offset = 0
      offset -= renewal while grid_start.advance(months: offset) > first_allowed
      Enumerator.new do |yielder|
        MAX_BOUNDARIES.times do |step|
          term_end = grid_start.advance(months: offset + (step * renewal)) - 1
          yielder << term_end if term_end >= first_allowed
        end
      end
    end
end
