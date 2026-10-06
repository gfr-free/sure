require "test_helper"

class Tax::EstimateTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.update!(currency: "EUR")
    @user = users(:empty)
    @year = Date.current.year
    @start = Date.new(@year, 1, 1)
  end

  test "without a profile there is no reserve and no tax" do
    account = depository(withheld: false)
    interest(account, 300)

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_not estimate.profile?
    assert_nil estimate.reserve
    assert_nil estimate.tax_for(account, 100, kind: "interest")
  end

  test "returns booked gross use the allowance no bank holds, then the rate" do
    profile(rate_interest: 25, rate_dividends: 25, annual_allowance: 1_000)
    bank = depository(withheld: true, allocation: 600)
    broker = depository(withheld: false)
    interest(bank, 100)
    interest(broker, 300)
    dividend(broker, 500)

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 600, estimate.allocated_allowance
    assert_equal 400, estimate.deferred_allowance
    # 800 gross on the broker, 400 of it free: 400 * 25%.
    assert_equal Money.new(100, "EUR"), estimate.reserve
    assert_equal 0, estimate.withheld_tax
    assert_equal 400, estimate.income_total(kind: "interest")
    assert_equal 500, estimate.income_total(kind: "dividends")
  end

  test "a withholding account is taxed beyond its exemption order" do
    profile(rate_interest: 25, annual_allowance: 1_000)
    bank = depository(withheld: true, allocation: 100)
    interest(bank, 300)

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 50, estimate.withheld_tax
    assert_equal Money.new(0, "EUR"), estimate.reserve
  end

  test "kinds without a rate stay out and are named" do
    profile(rate_interest: 25, annual_allowance: 0)
    broker = depository(withheld: false)
    dividend(broker, 400)

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal [ "dividends" ], estimate.missing_rates
    assert_equal Money.new(0, "EUR"), estimate.reserve
  end

  test "tax-free accounts and other people's accounts do not count" do
    profile(rate_interest: 25, annual_allowance: 0)
    exempt = depository(withheld: false)
    exempt.accountable.update!(tax_treatment: "tax_exempt")
    interest(exempt, 1_000)
    someone_else = depository(withheld: false, owner: users(:sso_only))
    interest(someone_else, 1_000)

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_equal 0, estimate.income_total
    assert_nil estimate.tax_for(exempt, 100, kind: "interest")
    assert_nil estimate.tax_for(someone_else, 100, kind: "interest")
  end

  test "last year's returns do not count this year" do
    profile(rate_interest: 25, annual_allowance: 0)
    broker = depository(withheld: false)
    interest(broker, 400, date: @start - 1)

    assert_equal 0, Tax::Estimate.new(@user, year: @year).income_total
  end

  test "banks show how much of their exemption order is used" do
    profile(rate_interest: 25, annual_allowance: 1_000)
    first = depository(withheld: true, allocation: 200, institution: "Bank A")
    second = depository(withheld: true, allocation: 300, institution: "Bank A")
    other = depository(withheld: true, allocation: 500, institution: "Bank B")
    interest(first, 250)
    interest(second, 100)
    interest(other, 50)

    banks = Tax::Estimate.new(@user, year: @year).banks

    assert_equal [ "Bank A", "Bank B" ], banks.map(&:label)
    assert_equal [ 500, 350 ], [ banks.first.allocation, banks.first.income ]
    assert_not banks.first.used_up?
    assert_equal 450, banks.last.remaining

    interest(second, 200)
    assert Tax::Estimate.new(@user, year: @year).banks.first.used_up?
  end

  test "exemption orders above the allowance are flagged" do
    profile(rate_interest: 25, annual_allowance: 1_000)
    depository(withheld: true, allocation: 800)
    depository(withheld: true, allocation: 400)

    assert Tax::Estimate.new(@user, year: @year).over_allocated?
  end

  test "tax_for uses what is left of the account's allowance" do
    profile(rate_interest: 25, annual_allowance: 1_000)
    bank = depository(withheld: true, allocation: 100)
    interest(bank, 60)

    estimate = Tax::Estimate.new(@user, year: @year)

    # 40 still free, 60 taxed at 25%.
    assert_equal 15, estimate.tax_for(bank, 100, kind: "interest")
  end

  test "tax_for counts only returns with a rate against the deferred allowance" do
    profile(rate_interest: 25, annual_allowance: 500)
    broker = depository(withheld: false)
    interest(broker, 300)
    dividend(broker, 400)

    estimate = Tax::Estimate.new(@user, year: @year)

    # Dividends have no rate and use no allowance: 200 of it is left.
    assert_equal 0, estimate.tax_for(broker, 100, kind: "interest")
    assert_equal 25, estimate.tax_for(broker, 300, kind: "interest")
  end

  test "the profile's withholding default applies when the account has none" do
    profile(rate_interest: 25, annual_allowance: 0, withheld_at_source_default: false)
    account = depository(withheld: nil)
    interest(account, 200)

    estimate = Tax::Estimate.new(@user, year: @year)

    assert_not estimate.withheld?(account)
    assert_equal Money.new(50, "EUR"), estimate.reserve
  end

  private
    def profile(**attributes)
      @user.tax_profiles.create!(valid_from_year: @year, currency: "EUR", **attributes)
    end

    def depository(withheld:, allocation: nil, institution: nil, owner: @user)
      Account.create!(
        family: @family, accountable: Depository.new(subtype: "savings"), owner: owner,
        name: "Savings #{SecureRandom.hex(4)}", currency: "EUR", balance: 10_000,
        tax_withheld_at_source: withheld, tax_allowance_allocation: allocation, institution_name: institution
      )
    end

    def interest(account, amount, date: @start + 10)
      booked(account, amount, "Interest", date)
    end

    def dividend(account, amount, date: @start + 20)
      booked(account, amount, "Dividend", date)
    end

    def booked(account, amount, label, date)
      account.entries.create!(
        date: [ date, Date.current ].min, amount: -amount, currency: account.currency, name: label,
        entryable: Transaction.new(investment_activity_label: label)
      )
    end
end
