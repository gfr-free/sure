# Production build only (branch prod-local of the fork, never upstream).
# Copied to config/initializers/zz_prod_warmup.rb by the image workflow.
#
# The web container restarts with every daily image update, and the first
# visitor then pays for template compilation, JIT warm-up and cold caches:
# measured on the NAS, the first request took two to three times the warm
# time and the dashboard needed 14 s. After boot, the web process therefore
# renders the pages a day starts with once, in-process, through the same
# Rack stack a browser would hit. Nothing is left behind: the throwaway
# session row is deleted again, and the auto-sync a page view can trigger
# is skipped for these requests.
#
#   PROD_WARMUP        "false" disables the warm-up
#   PROD_WARMUP_PATHS  comma-separated paths, default "/,/transactions"
#   PROD_WARMUP_DELAY  seconds to wait after boot, default 5
module ProdWarmup
  HEADER = "X-Prod-Warmup"

  # A warm-up page view must not kick off the family's auto-sync (bank APIs,
  # rate limits); that stays with the first real visit, as before.
  module SkipAutoSync
    private
      def family_needs_auto_sync?
        return false if request.headers[HEADER].present?

        super
      end
  end

  def self.enabled?
    return false unless Rails.env.production?
    return false if ENV["PROD_WARMUP"] == "false"

    # Only the web server: not console, runner, rake or the Sidekiq worker.
    defined?(::Rails::Server) ? true : false
  end

  def self.start
    Thread.new do
      sleep ENV.fetch("PROD_WARMUP_DELAY", 5).to_f
      Rails.application.executor.wrap { run }
    rescue => e
      Rails.logger.warn("prod-warmup: aborted: #{e.class}: #{e.message}")
    end
  end

  def self.run
    user = User.order(last_login_at: :desc, created_at: :asc).first
    unless user
      Rails.logger.info("prod-warmup: no user yet, nothing to warm")
      return
    end

    # Inserted directly: no callbacks, so neither the user's login time nor
    # the sessions counter changes, and the row is gone again below.
    session_id = SecureRandom.uuid
    Session.insert!({ id: session_id, user_id: user.id, created_at: Time.current, updated_at: Time.current })

    request = ActionDispatch::Request.new(Rails.application.env_config.merge("HTTP_HOST" => "localhost", "HTTPS" => "on"))
    jar = ActionDispatch::Cookies::CookieJar.build(request, {})
    jar.signed.permanent[:session_token] = { value: session_id, httponly: true }

    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! "localhost"
    browser.https!
    browser.cookies["session_token"] = jar[:session_token]

    paths.each do |path|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      browser.get path, headers: { HEADER => "1" }
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info("prod-warmup: GET #{path} -> #{browser.response.status} in #{ms}ms")
    end
  ensure
    Session.where(id: session_id).delete_all if session_id
  end

  def self.paths
    ENV.fetch("PROD_WARMUP_PATHS", "/,/transactions").split(",").map(&:strip).reject(&:blank?)
  end
end

Rails.application.config.to_prepare do
  ApplicationController.prepend(ProdWarmup::SkipAutoSync) if ProdWarmup.enabled?
end

Rails.application.config.after_initialize do
  ProdWarmup.start if ProdWarmup.enabled?
end
