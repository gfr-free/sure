require "test_helper"
require "open3"

class SidekiqConcurrencyConfigTest < ActiveSupport::TestCase
  test "sidekiq concurrency falls back to RAILS_MAX_THREADS, then 3" do
    with_env_overrides("SIDEKIQ_CONCURRENCY" => nil, "RAILS_MAX_THREADS" => nil) do
      assert_equal 3, sidekiq_concurrency
    end

    with_env_overrides("SIDEKIQ_CONCURRENCY" => "", "RAILS_MAX_THREADS" => "4") do
      assert_equal 4, sidekiq_concurrency
    end
  end

  test "SIDEKIQ_CONCURRENCY overrides RAILS_MAX_THREADS for sidekiq" do
    with_env_overrides("SIDEKIQ_CONCURRENCY" => "8", "RAILS_MAX_THREADS" => "3") do
      assert_equal 8, sidekiq_concurrency
    end
  end

  test "web process db pool follows RAILS_MAX_THREADS only" do
    with_env_overrides("SIDEKIQ_CONCURRENCY" => "8", "RAILS_MAX_THREADS" => "5") do
      assert_equal 5, database_pool(sidekiq_server: false)
    end

    with_env_overrides("SIDEKIQ_CONCURRENCY" => nil, "RAILS_MAX_THREADS" => nil) do
      assert_equal 3, database_pool(sidekiq_server: false)
    end
  end

  test "sidekiq process db pool is at least the sidekiq concurrency" do
    with_env_overrides("SIDEKIQ_CONCURRENCY" => "8", "RAILS_MAX_THREADS" => "3") do
      assert_equal 8, database_pool(sidekiq_server: true)
    end

    with_env_overrides("SIDEKIQ_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "5") do
      assert_equal 5, database_pool(sidekiq_server: true)
    end

    with_env_overrides("SIDEKIQ_CONCURRENCY" => nil, "RAILS_MAX_THREADS" => nil) do
      assert_equal 3, database_pool(sidekiq_server: true)
    end
  end

  private
    # Sidekiq renders config/sidekiq.yml before Rails boots, so render it in a
    # plain Ruby process without ActiveSupport, like the Sidekiq CLI does.
    def sidekiq_concurrency
      script = 'require "erb"; require "yaml"; ' \
        'puts YAML.safe_load(ERB.new(File.read(ARGV[0]), trim_mode: "-").result).fetch("concurrency")'
      output, status = Open3.capture2e(RbConfig.ruby, "-e", script, Rails.root.join("config/sidekiq.yml").to_s)
      assert status.success?, output
      Integer(output.strip)
    end

    def database_pool(sidekiq_server:)
      defined_here = sidekiq_server && !defined?(Sidekiq::CLI)
      Sidekiq.const_set(:CLI, Class.new) if defined_here

      if !sidekiq_server && defined?(Sidekiq::CLI)
        skip "Sidekiq::CLI is loaded in this process"
      end

      render_yaml("config/database.yml", aliases: true).dig("production", "pool")
    ensure
      Sidekiq.send(:remove_const, :CLI) if defined_here
    end

    def render_yaml(path, aliases: false)
      YAML.load(ERB.new(Rails.root.join(path).read, trim_mode: "-").result, aliases: aliases)
    end
end
