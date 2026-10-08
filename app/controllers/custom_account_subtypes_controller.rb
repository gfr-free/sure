# Settings page for a family's own account subtypes (CustomAccountSubtype,
# decision E22 stage 2). Preview only, decision E10.
class CustomAccountSubtypesController < ApplicationController
  before_action :require_preview_features!
  before_action :require_non_guest!, except: :index
  before_action :set_custom_account_subtype, only: %i[edit update destroy]

  def index
    @custom_account_subtypes = Current.family.custom_account_subtypes.alphabetically.to_a
    @custom_account_subtypes_by_type = @custom_account_subtypes.group_by(&:accountable_type)
    @account_counts = Current.family.accounts
      .where.not(custom_account_subtype_id: nil)
      .group(:custom_account_subtype_id)
      .count

    render layout: "settings"
  end

  # `template` ("Depository:cd", "Investment:") picks the built-in subtype the
  # new one starts from; the dialog reloads with its rules.
  def new
    accountable_type, subtype = parse_template(params[:template])
    @template = "#{accountable_type}:#{subtype}"
    @custom_account_subtype = CustomAccountSubtype.build_from_template(
      family: Current.family,
      accountable_type: accountable_type,
      subtype: subtype
    )
  end

  def create
    @custom_account_subtype = Current.family.custom_account_subtypes.new(create_params)

    if @custom_account_subtype.save
      redirect_to_index notice: t(".created")
    else
      @template = "#{@custom_account_subtype.accountable_type}:"
      render :new, formats: [ :html ], status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @custom_account_subtype.update(update_params)
      redirect_to_index notice: t(".updated")
    else
      render :edit, formats: [ :html ], status: :unprocessable_entity
    end
  end

  def destroy
    @custom_account_subtype.destroy!
    redirect_to custom_account_subtypes_path, notice: t(".deleted")
  end

  private
    # The form submits inside the modal frame, so a validation error renders
    # back into the dialog; success leaves the frame for the list.
    def redirect_to_index(notice:)
      respond_to do |format|
        format.html { redirect_to custom_account_subtypes_path, notice: notice }
        format.turbo_stream do
          flash[:notice] = notice
          render turbo_stream: turbo_stream.action(:redirect, custom_account_subtypes_path)
        end
      end
    end

    # A subtype's rules apply to every account that uses it, including other
    # members' accounts, so guests can look but not change them.
    def require_non_guest!
      return unless Current.user&.guest?

      redirect_to custom_account_subtypes_path, alert: t("custom_account_subtypes.guest_read_only")
    end

    def set_custom_account_subtype
      @custom_account_subtype = Current.family.custom_account_subtypes.find(params[:id])
    end

    def create_params
      params.require(:custom_account_subtype).permit(:accountable_type, :name, :liquidity, :tax_treatment)
    end

    # The account type stays fixed once created: accounts of that type use it.
    def update_params
      params.require(:custom_account_subtype).permit(:name, :liquidity, :tax_treatment)
    end

    def parse_template(value)
      accountable_type, subtype = value.to_s.split(":", 2)
      klass = Accountable.from_type(accountable_type)
      return [ "Depository", nil ] if klass.nil?

      subtype = nil unless subtype.present? && klass::SUBTYPES.key?(subtype)
      [ accountable_type, subtype ]
    end
end
