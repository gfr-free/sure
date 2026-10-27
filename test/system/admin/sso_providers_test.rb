require "application_system_test_case"

class Admin::SsoProvidersTest < ApplicationSystemTestCase
  setup do
    sign_in users(:sure_support_staff)
  end

  test "callback URLs wrap instead of widening the form at medium widths" do
    page.current_window.resize_to(800, 900)
    visit new_admin_sso_provider_path

    assert_selector "[data-admin-sso-form-target='callbackUrl']", text: "/auth/PROVIDER_NAME/callback"
    assert_callback_row_fits("callbackUrl")

    select "SAML 2.0", from: "sso_provider[strategy]"
    assert_callback_row_fits("samlCallbackUrl")
  end

  test "OIDC callback copy button copies the URL and confirms it" do
    visit new_admin_sso_provider_path
    stub_clipboard
    fill_in "sso_provider[name]", with: "keycloak"

    within(callback_row("callbackUrl")) { click_on "Copy" }

    assert_equal "#{app_origin}/auth/keycloak/callback", copied_text
    within(callback_row("callbackUrl")) { assert_button "Copied!" }
  end

  test "SAML callback copy button copies the URL and confirms it" do
    visit new_admin_sso_provider_path
    stub_clipboard
    select "SAML 2.0", from: "sso_provider[strategy]"
    fill_in "sso_provider[name]", with: "okta"

    within(callback_row("samlCallbackUrl")) { click_on "Copy" }

    assert_equal "#{app_origin}/auth/okta/callback", copied_text
    within(callback_row("samlCallbackUrl")) { assert_button "Copied!" }
  end

  private
    def assert_callback_row_fits(target)
      # The body clips overflow, so a too-wide form shows up as body scroll width
      # beyond the viewport rather than as a window scrollbar.
      assert_operator page.evaluate_script("document.body.scrollWidth"),
                      :<=, page.evaluate_script("document.body.clientWidth")

      form_right = right_edge(find("form[data-controller~='admin-sso-form']"))
      within(callback_row(target)) do
        assert_operator right_edge(find("code")), :<=, form_right
        assert_operator right_edge(find_button("Copy")), :<=, form_right
      end
    end

    def right_edge(element)
      page.evaluate_script("arguments[0].getBoundingClientRect().right", element)
    end

    # Headless Chrome has no focused clipboard to write to, so record what the
    # page tries to copy instead.
    def stub_clipboard
      page.execute_script(<<~JS)
        window.__copiedText = null
        Object.defineProperty(navigator, "clipboard", {
          configurable: true,
          value: { writeText: (text) => { window.__copiedText = text; return Promise.resolve() } }
        })
      JS
    end

    def callback_row(target)
      "[data-controller='clipboard']:has([data-admin-sso-form-target='#{target}'])"
    end

    def app_origin
      page.evaluate_script("window.location.origin")
    end

    def copied_text
      page.evaluate_script("window.__copiedText")
    end
end
