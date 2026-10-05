require "test_helper"

# Loss pots, realised gains and joint accounts in the tax estimate (decision
# E21, STEUER.md S-3 / V-1).
class Tax::EstimateLossPotTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 6, 15)
    @family = families(:empty)
    @family.update!(currency: "EUR")
    @user = users(:empty)
    @partner = users(:sso_only)
    @year = 2026
    @share = security("SHR", "stock")
    @fund = security("FND", "etf")
  end

  test "a realised gain is taxed at the gains rate after the allowance" do
    profile(rate_gains: 25, annual_allowance: 100)
    broker = brokerage
    position(broker, @share, cost: 10)
    sell(broker, @share, qty: 10, price: 30, date: Date.new(@year, 3, 1))

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 200, estimate.income_total(kind: "gains")
    # (200 - 100 allowance) * 25%.
    assert_equal Money.new(25, "EUR"), estimate.reserve
  end

  test "a share gain takes from the stocks pot first, then the general pot" do
    profile(rate_gains: 25, rate_interest: 25, annual_allowance: 0)
    broker = brokerage
    pot(broker, "stocks", 150, Date.new(@year - 1, 12, 31))
    pot(broker, "general", 30, Date.new(@year - 1, 12, 31))
    position(broker, @share, cost: 10)
    sell(broker, @share, qty: 10, price: 30, date: Date.new(@year, 3, 1))
    interest(broker, 40, Date.new(@year, 4, 1))

    estimate = Tax::Estimate.new(@user, year: @year)
    stocks, general = estimate.pot_states

    # 200 gain: 150 from the stocks pot, 30 from the general pot, 20 taxed.
    # The interest finds both pots empty for it and is taxed in full.
    assert_equal [ 150, 0 ], [ stocks.used, stocks.remaining ]
    assert_equal [ 30, 0 ], [ general.used, general.remaining ]
    assert_equal 180, estimate.offset_total
    assert_equal Money.new(15, "EUR"), estimate.reserve
  end

  test "the stocks pot does not offset interest" do
    profile(rate_interest: 25, annual_allowance: 0)
    broker = brokerage
    pot(broker, "stocks", 500, Date.new(@year - 1, 12, 31))
    interest(broker, 100, Date.new(@year, 2, 1))

    assert_equal Money.new(25, "EUR"), Tax::Estimate.new(@user, year: @year).reserve
  end

  test "a share loss fills the stocks pot when the account has one, else it offsets everything" do
    profile(rate_gains: 25, rate_interest: 25, annual_allowance: 0)
    with_split = brokerage
    pot(with_split, "stocks", 0, Date.new(@year - 1, 12, 31))
    position(with_split, @share, cost: 30)
    sell(with_split, @share, qty: 10, price: 20, date: Date.new(@year, 2, 1))
    interest(with_split, 100, Date.new(@year, 3, 1))

    single = brokerage
    position(single, @share, cost: 30)
    sell(single, @share, qty: 10, price: 20, date: Date.new(@year, 2, 1))
    interest(single, 100, Date.new(@year, 3, 1))

    estimate = Tax::Estimate.new(@user, year: @year)
    states = estimate.pot_states.index_by { |state| [ state.account.id, state.kind ] }

    assert_equal 100, states[[ with_split.id, "stocks" ]].remaining
    assert_equal 0, states[[ single.id, "general" ]].remaining
    # Only the interest on the account with a stocks pot is taxed.
    assert_equal Money.new(25, "EUR"), estimate.reserve
  end

  test "a fund loss goes into the general pot and offsets interest on the same account only" do
    profile(rate_interest: 25, annual_allowance: 0)
    broker = brokerage
    other = brokerage
    position(broker, @fund, cost: 30)
    sell(broker, @fund, qty: 10, price: 26, date: Date.new(@year, 2, 1))
    interest(broker, 100, Date.new(@year, 3, 1))
    interest(other, 100, Date.new(@year, 3, 1))

    # 40 loss offsets 40 of the first account's interest: (60 + 100) * 25%.
    assert_equal Money.new(40, "EUR"), Tax::Estimate.new(@user, year: @year).reserve
  end

  test "returns up to the entered date are already in the balance" do
    profile(rate_gains: 25, annual_allowance: 0)
    broker = brokerage
    position(broker, @fund, cost: 10)
    sell(broker, @fund, qty: 5, price: 2, date: Date.new(@year, 2, 1)) # loss of 40, already in the pot
    pot(broker, "general", 100, Date.new(@year, 3, 31))
    sell(broker, @fund, qty: 5, price: 50, date: Date.new(@year, 5, 1)) # gain of 200

    estimate = Tax::Estimate.new(@user, year: @year)
    general = estimate.pot_states.sole

    assert_equal [ 100, 0, 100 ], [ general.entered, general.added, general.used ]
    assert_equal Date.new(@year, 3, 31), general.entered_on
    assert_equal Money.new(25, "EUR"), estimate.reserve
  end

  test "returns up to the entered date are netted with each other, in any order" do
    profile(rate_gains: 25, annual_allowance: 0)
    broker = brokerage
    position(broker, @fund, cost: 10)
    sell(broker, @fund, qty: 10, price: 110, date: Date.new(@year, 1, 10)) # gain of 1000
    sell(broker, @fund, qty: 10, price: 0, date: Date.new(@year, 2, 1)) # loss of 100
    sell(broker, @fund, qty: 10, price: 0, date: Date.new(@year, 2, 2)) # loss of 100
    pot(broker, "general", 0, Date.new(@year, 3, 31))

    estimate = Tax::Estimate.new(@user, year: @year)

    # 1000 - 200 netted before the entered date; the pot itself is untouched.
    assert_equal 200, estimate.offset_total
    assert_equal [ 0, 0 ], [ estimate.pot_states.sole.added, estimate.pot_states.sole.used ]
    assert_equal Money.new(200, "EUR"), estimate.reserve
  end

  test "a balance from before last year is not used and is flagged" do
    profile(rate_interest: 25, annual_allowance: 0)
    broker = brokerage
    pot(broker, "general", 100, Date.new(@year - 2, 12, 31))
    interest(broker, 100, Date.new(@year, 2, 1))

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal Money.new(25, "EUR"), estimate.reserve
    assert estimate.pot_states.sole.outdated
  end

  test "the capital gains line shows sales with a gain, losses go to the offset" do
    profile(rate_gains: 25, annual_allowance: 0)
    broker = brokerage
    position(broker, @fund, cost: 10)
    sell(broker, @fund, qty: 10, price: 6, date: Date.new(@year, 1, 10)) # loss of 40
    sell(broker, @fund, qty: 10, price: 20, date: Date.new(@year, 2, 1)) # gain of 100

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 100, estimate.returns_total("gains")
    assert_equal 40, estimate.offset_total
    assert_equal Money.new(15, "EUR"), estimate.reserve
  end

  test "a balance from an earlier year only counts when the pot carries forward" do
    profile(rate_interest: 25, annual_allowance: 0)
    broker = brokerage
    general = pot(broker, "general", 100, Date.new(@year - 1, 12, 31))
    interest(broker, 100, Date.new(@year, 2, 1))

    assert_equal Money.new(0, "EUR"), Tax::Estimate.new(@user, year: @year).reserve

    general.update!(carry_forward: false)
    assert_equal Money.new(25, "EUR"), Tax::Estimate.new(@user, year: @year).reserve
    # The entered year itself still uses it.
    assert_equal 100, Tax::Estimate.new(@user, year: @year - 1).pot_states.sole.entered
  end

  test "a joint account splits its returns 50/50 unless a share is set" do
    profile(rate_interest: 25, annual_allowance: 0)
    profile(rate_interest: 40, annual_allowance: 0, user: @partner)
    savings = depository(joint: @partner)
    interest(savings, 200, Date.new(@year, 2, 1))

    assert_equal Money.new(25, "EUR"), Tax::Estimate.new(@user, year: @year).reserve
    assert_equal Money.new(40, "EUR"), Tax::Estimate.new(@partner, year: @year).reserve
    # 50 * 25% + 50 * 40%.
    assert_equal 32.5, Tax::Estimate.tax_for_account(savings, 100, kind: "interest", year: @year)

    savings.update!(tax_owner_share: 75)
    assert_equal 150, Tax::Estimate.new(@user, year: @year).income_total
    assert_equal 50, Tax::Estimate.new(@partner, year: @year).income_total
  end

  test "a joint person who no longer has the account shared leaves the owner alone" do
    profile(rate_interest: 25, annual_allowance: 0)
    savings = depository(joint: @partner)
    interest(savings, 200, Date.new(@year, 2, 1))
    savings.account_shares.delete_all

    assert_equal 200, Tax::Estimate.new(@user, year: @year).income_total
    assert_equal({ @user => 1 }, savings.reload.tax_shares)
    savings.update!(name: "Still saves")
  end

  test "a joint account's exemption order is split by the shares too" do
    profile(rate_interest: 25, annual_allowance: 1_000)
    savings = depository(joint: @partner, withheld: true, allocation: 200)

    assert_equal 100, Tax::Estimate.new(@user, year: @year).allocated_allowance
  end

  test "sales without a purchase price are counted and left out" do
    profile(rate_gains: 25, annual_allowance: 0)
    broker = brokerage
    sell(broker, @share, qty: 1, price: 10, date: Date.new(@year, 2, 1))

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 1, estimate.unknown_gains_count
    assert_equal 0, estimate.income_total
  end

  test "gains on a crypto account count as crypto" do
    profile(rate_crypto: 0, rate_gains: 25, annual_allowance: 0)
    wallet = Account.create!(family: @family, owner: @user, accountable: Crypto.new(tax_treatment: "taxable"),
                             name: "Wallet", currency: "EUR", balance: 1_000)
    coin = security("CNX", "cryptocurrency")
    position(wallet, coin, cost: 1)
    sell(wallet, coin, qty: 100, price: 3, date: Date.new(@year, 2, 1))

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 200, estimate.income_total(kind: "crypto")
    assert_equal Money.new(0, "EUR"), estimate.reserve
  end

  private
    def profile(user: @user, **attributes)
      user.tax_profiles.create!(valid_from_year: @year - 1, currency: "EUR", withheld_at_source_default: false, **attributes)
    end

    def security(ticker, sub_class)
      Security.create!(ticker: "#{ticker}#{SecureRandom.hex(3).upcase}", name: ticker, asset_sub_class: sub_class)
    end

    def brokerage
      Account.create!(family: @family, owner: @user, accountable: Investment.new(subtype: "brokerage"),
                      name: "Broker #{SecureRandom.hex(3)}", currency: "EUR", balance: 10_000)
    end

    def depository(joint:, withheld: false, allocation: nil)
      account = Account.create!(family: @family, owner: @user, accountable: Depository.new(subtype: "savings"),
                                name: "Joint #{SecureRandom.hex(3)}", currency: "EUR", balance: 10_000,
                                tax_withheld_at_source: withheld, tax_allowance_allocation: allocation)
      account.share_with!(joint)
      account.update!(tax_joint_user: joint)
      account
    end

    def pot(account, kind, amount, date)
      pot = account.loss_pots.find_or_create_by!(kind: kind)
      pot.snapshots.create!(date: date, amount: amount)
      pot
    end

    def position(account, security, cost:)
      Holding.create!(account: account, security: security, date: Date.new(@year, 1, 1), qty: 100,
                      price: cost, amount: cost * 100, currency: "EUR", cost_basis: cost)
    end

    def sell(account, security, qty:, price:, date:)
      account.entries.create!(
        date: date, name: "Sell #{security.ticker}", amount: -qty * price, currency: "EUR",
        entryable: Trade.new(security: security, qty: -qty, price: price, currency: "EUR")
      )
    end

    def interest(account, amount, date)
      account.entries.create!(
        date: date, amount: -amount, currency: account.currency, name: "Interest",
        entryable: Transaction.new(investment_activity_label: "Interest")
      )
    end
end
