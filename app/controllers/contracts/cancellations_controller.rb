# Recording a cancellation: sent (new/create), confirmed by the provider
# (update) or withdrawn after a retention offer (destroy). Ending the linked
# bills is offered, and off unless the user ticks it.
class Contracts::CancellationsController < Contracts::BaseController
  before_action :require_editable

  def new
    @sent_on = @contract.cancelled_on || Date.current
    @ends_on = @contract.ends_on
    render layout: dialog_layout
  end

  def create
    @sent_on = parse_date(params.dig(:cancellation, :sent_on)) || Date.current
    @ends_on = parse_date(params.dig(:cancellation, :ends_on))

    if @ends_on.present? && @ends_on < @sent_on
      @error = t(".ends_before_sent")
      return render :new, status: :unprocessable_entity, layout: dialog_layout
    end

    @contract.record_cancellation!(
      sent_on: @sent_on,
      ends_on: @ends_on,
      end_linked_bills: ActiveModel::Type::Boolean.new.cast(params.dig(:cancellation, :end_linked_bills)),
      bills: RecurringTransaction.writable_by(Current.user)
    )

    flash[:notice] = t(".success")

    respond_to do |format|
      format.html { redirect_to contract_path(@contract) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, contract_path(@contract)) }
    end
  end

  def update
    @contract.confirm_cancellation!(confirmed_on: parse_date(params.dig(:cancellation, :confirmed_on)) || Date.current)
    redirect_to contract_path(@contract), notice: t(".success")
  end

  def destroy
    @contract.withdraw_cancellation!
    redirect_to contract_path(@contract), notice: t(".success")
  end

  private

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
end
