# Who else may see a contract. Mirrors AccountSharingsController: the owner
# (or a full_control share) chooses members and their permission tier.
class Contracts::SharingsController < Contracts::BaseController
  before_action :require_manageable

  def show
    @family_members = eligible_members.order(:first_name, :email)
    @contract_shares = @contract.contract_shares.index_by(&:user_id)
    render layout: dialog_layout
  end

  def update
    ContractShare.transaction do
      sharing_members_params.each do |member_params|
        user = eligible_members.find_by(id: member_params[:user_id])
        next unless user

        share = @contract.contract_shares.find_by(user: user)

        if ActiveModel::Type::Boolean.new.cast(member_params[:shared])
          permission = ContractShare::PERMISSIONS.include?(member_params[:permission]) ? member_params[:permission] : (share&.permission || "read_only")
          permission = "read_only" if user.guest?
          share ||= @contract.contract_shares.new(user: user)
          share.update!(permission: permission)
        elsif share
          share.destroy!
        end
      end
    end

    redirect_to contract_path(@contract), notice: t(".success")
  end

  private

    def eligible_members
      Current.family.users.where.not(id: @contract.owner_id).where(active: true)
    end

    def sharing_members_params
      return [] unless params.dig(:sharing, :members)

      params.require(:sharing).permit(members: [ :user_id, :shared, :permission ])[:members]&.values || []
    end
end
