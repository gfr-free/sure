class Category::DeletionsController < ApplicationController
  before_action :require_non_guest!
  before_action :set_category
  before_action :set_replacement_category, only: :create

  def new
    @replacement_categories = Category::Group.ordered(Current.family.categories).without(@category)
    # Labeled among the offered categories only, so the one being deleted
    # cannot make another look like a duplicate.
    @replacement_labels = Category.option_labels(@replacement_categories, with_parent: true)
  end

  def create
    @category.replace_and_destroy! @replacement_category

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  private
    def set_category
      @category = Current.family.categories.find(params[:category_id])
    end

    def set_replacement_category
      if params[:replacement_category_id].present?
        @replacement_category = Current.family.categories.find(params[:replacement_category_id])
      end
    end
end
