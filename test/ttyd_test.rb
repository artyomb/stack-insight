# frozen_string_literal: true

require 'minitest/autorun'
require 'async'
require_relative '../src/ttyd'

class ServerTtydTest < Minitest::Test
  class EofSocket
    def read = nil
    def write(*) = nil
    def flush = nil
  end

  class BlockingSocket < EofSocket
    attr_reader :read_stopped

    def read
      sleep 60
    ensure
      @read_stopped = true
    end
  end

  def setup
    ServerTtyd::SESSIONS_MUTEX.synchronize { ServerTtyd::SESSIONS.clear }
    @app = ServerTtyd.new!
  end

  def teardown
    sessions = ServerTtyd::SESSIONS_MUTEX.synchronize { ServerTtyd::SESSIONS.values }
    sessions.each { @app.send(:stop_session, _1) }
  end

  def test_ttyd_exits_after_all_websocket_clients_disconnect
    command = @app.send(:ttyd_command, { cid: 'abc123', port: 8000 }, 'bash')

    assert_includes command, '--exit-no-conn'
    assert_equal 'lo', command[command.index('-i') + 1]
    assert_equal ['docker', 'exec', '-it', 'abc123', 'bash'], command.last(5)
  end

  def test_bridge_stops_the_other_direction_after_disconnect
    client = EofSocket.new
    ttyd = BlockingSocket.new

    Async do |task|
      task.with_timeout(1) { @app.send(:bridge_websockets, client, ttyd) }
    end.wait

    assert ttyd.read_stopped
  end

  def test_remove_session_does_not_delete_its_replacement
    original = { cid: 'abc123' }
    replacement = { cid: 'abc123' }
    ServerTtyd::SESSIONS_MUTEX.synchronize { ServerTtyd::SESSIONS['abc123'] = replacement }

    @app.send(:remove_session, original)

    assert_same replacement, ServerTtyd::SESSIONS['abc123']
  end

  def test_unconnected_session_is_reclaimed_after_timeout
    session = {
      cid: 'abc123',
      connected: false,
      last_access: @app.send(:monotonic_time) - ServerTtyd::SESSION_START_TIMEOUT - 1,
      thread: Thread.current,
      watchdog: Thread.current
    }
    ServerTtyd::SESSIONS_MUTEX.synchronize { ServerTtyd::SESSIONS['abc123'] = session }

    @app.send(:expire_unconnected_session, session)

    refute ServerTtyd::SESSIONS.key?('abc123')
  end

  def test_reserved_port_is_not_reused_before_ttyd_binds
    session = { cid: 'abc123', port: 8000, thread: Thread.current }
    ServerTtyd::SESSIONS_MUTEX.synchronize { ServerTtyd::SESSIONS['abc123'] = session }
    @app.define_singleton_method(:port_free?) { |_port| true }

    assert_equal 8001, @app.send(:find_port)
  end

  def test_invalid_container_reference_is_rejected_before_docker_exec
    error = assert_raises(RuntimeError) { @app.send(:start_session, 'abc123;touch-pwned') }

    assert_equal 'Invalid container reference: abc123;touch-pwned', error.message
  end
end
