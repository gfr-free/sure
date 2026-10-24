# The filter menu of the transactions index, loaded into its popover on first
# open. Rendering every account, category, tag and merchant on each index
# request cost a noticeable share of the page's render time even though the
# menu starts closed.
class Transactions::SearchFiltersController < ApplicationController
  include TransactionSearchParams

  def show
    @q = search_params
  end
end
