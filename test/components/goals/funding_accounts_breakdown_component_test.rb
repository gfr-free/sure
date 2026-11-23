require "test_helper"

class Goals::FundingAccountsBreakdownComponentTest < ViewComponent::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = Account.create!(family: @family, accountable: Investment.new, name: "Pension", currency: "USD", balance: 10_000)
    create_transaction(account: @account, amount: -300, date: 10.days.ago.to_date)
    interest = Trade::CreateForm.new(account: @account, type: "interest", amount: 50, date: 40.days.ago.to_date, currency: "USD").create
    assert interest.persisted?, interest.errors.full_messages.to_sentence
    @account.balances.create!(date: 5.days.ago.to_date, balance: 10_000, currency: "USD", net_market_flows: 100)
    @account.balances.create!(date: 60.days.ago.to_date, balance: 9_500, currency: "USD", net_market_flows: -30)
  end

  # Interest is booked as a trade and market gains live on the balance rows.
  test "the columns count interest and, on the balance basis, the net market gain of each window" do
    row = row_for(goal_with_basis("balance"))

    assert_equal 400, row[:last_30_money].amount
    assert_equal 420, row[:last_90_money].amount
  end

  test "on the contributions basis the columns count interest but not market gains" do
    row = row_for(goal_with_basis("contributions"))

    assert_equal 300, row[:last_30_money].amount
    assert_equal 350, row[:last_90_money].amount
  end

  test "a market loss over a window reads as zero, like an outflow" do
    @account.balances.find_by(date: 5.days.ago.to_date).update!(net_market_flows: -500)
    row = row_for(goal_with_basis("balance"))

    assert_equal 300, row[:last_30_money].amount
    assert_equal 350, row[:last_90_money].amount
  end

  private
    def goal_with_basis(basis)
      goal = @family.goals.create!(name: "Retirement #{basis}", target_amount: 50_000, currency: "USD") do |g|
        g.goal_accounts.build(account: @account)
      end
      goal.update_column(:progress_basis, basis)
      Goal.find(goal.id)
    end

    def row_for(goal)
      Goals::FundingAccountsBreakdownComponent.new(goal: goal).rows.find { |r| r[:account] == @account }
    end
end
