# The accountable behind a person's clearing account ("Verrechnungskonto").
# Its balance is what that person owes the user (positive) or what the user
# owes them (negative). It only ever holds transfer legs from assigned
# transactions and the user's own entries, so it is a cash-type asset.
class Clearing < ApplicationRecord
  include Accountable

  belongs_to :counterparty

  class << self
    def color
      "#7A5AF8"
    end

    def icon
      "users"
    end

    def classification
      "asset"
    end
  end
end
