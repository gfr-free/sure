# Ending a contract, in one step whether it was cancelled or simply runs out:
# the user records the end date (new/create) or takes it back (destroy). The
# linked bills this user may change end on the same date. A successor can be
# named on the way: an existing contract, or a new one whose form opens next.
class Contracts::EndingsController < Contracts::BaseController
  before_action :require_editable

  NEW_SUCCESSOR = "new"

  def new
    @ends_on = @contract.ends_on || @contract.notice_schedule.earliest_end_on || Date.current
    @successor_id = @contract.replaced_by_id
    @ends_bills = RecurringTransaction.writable_by(Current.user)
                                      .where(contract_id: @contract.id, status: %w[active inactive paused])
                                      .exists?
    render layout: dialog_layout
  end

  def create
    @ends_on = parse_date(params.dig(:ending, :ends_on))
    @successor_id = params.dig(:ending, :replaced_by_id).presence

    if @ends_on.nil?
      @error = t(".date_required")
      return render :new, status: :unprocessable_entity, layout: dialog_layout
    end

    if @contract.started_on.present? && @ends_on < @contract.started_on
      @error = t(".ends_before_start")
      return render :new, status: :unprocessable_entity, layout: dialog_layout
    end

    unless assign_successor
      @error = t(".successor_invalid")
      return render :new, status: :unprocessable_entity, layout: dialog_layout
    end

    @contract.end_contract!(on: @ends_on, bills: RecurringTransaction.writable_by(Current.user))

    flash[:notice] = t(".success")

    # The new contract's form opens in the same dialog and links back to this
    # one when saved.
    return redirect_to new_contract_path(predecessor_id: @contract.id), status: :see_other if @successor_id == NEW_SUCCESSOR

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

    # Contracts the user can see may be named as the successor, as in the
    # contract form.
    def successor_options
      Current.family.contracts.accessible_by(Current.user).where.not(id: @contract.id)
    end
    helper_method :successor_options

    # Returns false for a successor the user cannot pick. "No successor"
    # clears the link, except one to a contract this user cannot see: that one
    # is not in the list, so the dialog could not have shown it.
    def assign_successor
      return true if @successor_id == NEW_SUCCESSOR

      if @successor_id.blank?
        @contract.replaced_by = nil if @contract.replaced_by_id.nil? || successor_options.exists?(id: @contract.replaced_by_id)
        return true
      end

      @contract.replaced_by = successor_options.find_by(id: @successor_id)
      @contract.replaced_by.present?
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
end
