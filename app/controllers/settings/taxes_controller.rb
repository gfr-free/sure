# The person's tax profile for returns (decision E20, STEUER.md S-1/S-2):
# rates per income type, allowance and the withholding default, plus what
# Sure estimates from them this year. Per person, so it always edits
# Current.user's own profile. Preview only (decision E10).
class Settings::TaxesController < ApplicationController
  layout "settings"

  before_action :require_preview_features!

  def show
    @year = today.year
    @profile = form_profile_for(@year)
    @profiles = Current.user.tax_profiles.chronological.to_a
    @estimates = [ @year, @year - 1 ].map { |year| Tax::Estimate.new(Current.user, year: year) }
  end

  # Saves the profile for the year it applies from; a new year starts a new
  # entry, so earlier years keep their rates.
  def update
    attributes = profile_params
    year = Integer(attributes.delete(:valid_from_year).to_s, exception: false)
    if year.nil?
      return redirect_to settings_taxes_path, alert: t(".invalid_year")
    end

    profile = Current.user.tax_profiles.find_or_initialize_by(valid_from_year: year)
    profile.currency ||= Current.family.currency

    if profile.update(attributes)
      redirect_to settings_taxes_path, notice: t(".saved")
    else
      redirect_to settings_taxes_path, alert: profile.errors.full_messages.to_sentence
    end
  end

  # Marks a year's tax reserve as paid (or open again).
  def settle
    year = Integer(params[:year].to_s, exception: false)
    return redirect_to(settings_taxes_path) if year.nil? || year > today.year

    Current.user.settle_tax_reserve!(year, settled: params[:settled] != "false")
    redirect_to settings_taxes_path, notice: t(".updated")
  end

  def destroy_profile
    Current.user.tax_profiles.find(params[:profile_id]).destroy!
    redirect_to settings_taxes_path, notice: t(".removed")
  end

  private
    # The form always edits the given year: a profile inherited from an earlier
    # year is shown as an unsaved copy, so saving starts a new entry and the
    # earlier year keeps its rates.
    def form_profile_for(year)
      current = TaxProfile.for(Current.user, year)
      return current if current&.valid_from_year == year
      return current.dup.tap { |copy| copy.valid_from_year = year } if current

      Current.user.tax_profiles.build(valid_from_year: year, currency: Current.family.currency)
    end

    def today
      Account.liquidity_today_for(Current.family)
    end

    def profile_params
      params.require(:tax_profile).permit(
        :valid_from_year, :currency, :rate_interest, :rate_dividends, :rate_gains, :rate_crypto,
        :annual_allowance, :withheld_at_source_default
      )
    end
end
