# Ending a contract, in one step whether it was cancelled or simply runs out:
# the user records the end date (new/create) or takes it back (destroy). The
# linked bills this user may change end on the same date.
class Contracts::EndingsController < Contracts::BaseController
  before_action :require_editable

  def new
    @ends_on = @contract.ends_on || @contract.notice_schedule.earliest_end_on || Date.current
    render layout: dialog_layout
  end

  def create
    @ends_on = parse_date(params.dig(:ending, :ends_on))

    if @ends_on.nil?
      @error = t(".date_required")
      return render :new, status: :unprocessable_entity, layout: dialog_layout
    end

    if @contract.started_on.present? && @ends_on < @contract.started_on
      @error = t(".ends_before_start")
      return render :new, status: :unprocessable_entity, layout: dialog_layout
    end

    @contract.end_contract!(on: @ends_on, bills: RecurringTransaction.writable_by(Current.user))

    flash[:notice] = t(".success")

    respond_to do |format|
      format.html { redirect_to contract_path(@contract) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, contract_path(@contract)) }
    end
  end

  def destroy
    @contract.reopen!(bills: RecurringTransaction.writable_by(Current.user))
    redirect_to contract_path(@contract), notice: t(".success")
  end

  private

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
end
