require "test_helper"

# User#with_active_lock! serializes session and token issuance against changes
# to the user row (deactivation, password change, purge). It must not also wait
# on transactions that merely write a row pointing at the user: Postgres takes
# FOR KEY SHARE on the referenced user row for every such foreign-key insert,
# and a FOR UPDATE lock waits on that until the other transaction commits. A
# long import that creates accounts owned by the user, for example, would then
# hold that user's sign-in (and a Puma thread) for its whole duration.
class UserActiveLockTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  test "issuing a session does not wait on an open transaction that inserted a row referencing the user" do
    with_user_row_held_elsewhere("INSERT INTO chats (user_id, title, created_at, updated_at) VALUES ($1, 'Held', now(), now())") do
      session = with_short_lock_timeout do
        @user.with_active_lock! { @user.sessions.create! }
      end

      assert session.persisted?
    end
  end

  test "issuing a session still waits on a concurrent update of the user row" do
    with_user_row_held_elsewhere("UPDATE users SET active = active WHERE id = $1") do
      assert_raises(ActiveRecord::LockWaitTimeout) do
        with_short_lock_timeout { @user.with_active_lock! { flunk "lock must not be granted" } }
      end
    end
  end

  test "issuing a session still waits on a FOR UPDATE lock, as a delete of the user row takes" do
    with_user_row_held_elsewhere("SELECT 1 FROM users WHERE id = $1 FOR UPDATE") do
      assert_raises(ActiveRecord::LockWaitTimeout) do
        with_short_lock_timeout { @user.with_active_lock! { flunk "lock must not be granted" } }
      end
    end
  end

  private

    # Runs sql against @user.id in an open transaction on a separate PG
    # session, so its row locks are really held while the block runs.
    # Fixtures are committed before the test transaction starts, so the
    # other session sees the user.
    def with_user_row_held_elsewhere(sql)
      config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
      other = PG.connect({
        dbname: config[:database], host: config[:host], port: config[:port],
        user: config[:username], password: config[:password]
      }.compact)
      other.exec("BEGIN")
      other.exec_params(sql, [ @user.id ])
      yield
    ensure
      other&.exec("ROLLBACK")
      other&.close
    end

    def with_short_lock_timeout
      ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
      yield
    end
end
