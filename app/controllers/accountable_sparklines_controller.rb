class AccountableSparklinesController < ApplicationController
  include AccountSetSparkline

  def show
    @accountable = Accountable.from_type(params[:accountable_type]&.classify)

    render_account_set_sparkline
  end

  private
    # Same accounts the sidebar group total sums: accessible to the current
    # user, visible, included in reports and counted in their finances (owned,
    # or shared with include_in_finances).
    def account_scope
      Current.accessible_accounts
        .visible
        .included_in_reports
        .included_in_finances_for(Current.user)
        .where(accountable_type: @accountable.name)
    end

    def sparkline_favorable_direction
      @accountable.favorable_direction
    end

    def sparkline_cache_name
      "#{@accountable.name}_sparkline"
    end
end
