class Transactions::FiltersController < ApplicationController
  include TransactionSearchParams

  # Renders the transactions search filter menu, lazy-loaded into the filter
  # popover so the index doesn't pay for the account/category/merchant/tag
  # lists on every request while the popover is closed.
  def show
    @q = search_params
    render layout: false if turbo_frame_request?
  end
end
