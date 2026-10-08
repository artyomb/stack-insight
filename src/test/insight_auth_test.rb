# frozen_string_literal: true

require_relative 'auth_helpers'

class InsightAuthTest < Minitest::Test
  include AuthHelpers

  def setup = setup_auth

  def test_absent_configuration_preserves_legacy_mode
    assert_nil InsightAuth.options({})
  end

  def test_partial_or_blank_configuration_fails_startup
    InsightAuth::SETTINGS.each do |name|
      assert_raises(ArgumentError) { InsightAuth.options(name => 'configured') }
      assert_raises(ArgumentError) { InsightAuth.options(name => '') }
    end
  end

  def test_full_configuration_passes_explicit_audience_and_key_endpoint
    values = { 'OAUTH_SLIM_KEY_ENDPOINT' => 'http://auth.test/keys', 'OAUTH_SLIM_AUDIENCE' => AUDIENCE }
    assert_equal({ key_endpoint: values.values[0], audience: AUDIENCE }, InsightAuth.options(values))
  end

  def test_verified_oauth_is_required_without_basic_auth
    assert_equal 401, @guard.call(env_for(nil))[0]
    assert_equal 401, @guard.call(env_for('forged'))[0]
    assert_empty @seen
    assert_equal 200, @guard.call(env_for)[0]
    assert_equal '', @seen.last.fetch('oauth_slim.identity').fetch('role')
  end

  def test_verified_oauth_does_not_require_an_additional_role
    assert_equal 200, @guard.call(env_for(assertion(role: 'viewer')))[0]
  end

  def test_credentials_are_removed_before_framework_logging
    request = env_for(assertion, HTTP_AUTHORIZATION: 'Basic b3BlcmF0b3I6c2VjcmV0',
                      HTTP_COOKIE: 'auth_token=private', HTTP_X_ACCESS_TOKEN: 'private')
    assert_equal 200, @guard.call(request)[0]
    %w[HTTP_X_AUTH_JWT HTTP_X_AUTHSLIM HTTP_X_TOKEN HTTP_X_ACCESS_TOKEN HTTP_AUTHORIZATION HTTP_COOKIE].each do |name|
      refute @seen.last.key?(name), name
    end
    assert @seen.last.fetch('oauth_slim.identity').frozen?
  end

  def test_same_assertion_is_consumed_when_the_application_fails
    guard = make_guard(->(_) { raise 'application failed' })
    advance(11)
    token = assertion
    assert_raises(RuntimeError) { guard.call(env_for(token)) }
    assert_equal 401, guard.call(env_for(token))[0]
  end

  def test_replay_and_wrong_operation_are_denied
    token = assertion
    assert_equal 200, @guard.call(env_for(token))[0]
    assert_equal 401, @guard.call(env_for(token))[0]
    assert_equal 401, @guard.call(env_for(assertion, target: '/private?a=2&a=1'))[0]
    assert_equal 401, @guard.call(env_for(assertion, method: 'POST'))[0]
    assert_equal 401, @guard.call(env_for(assertion(aud: 'another-service')))[0]
    assert_equal 401, @guard.call(env_for(assertion(iss: 'untrusted')))[0]
    assert_equal 401, @guard.call(env_for(assertion, REQUEST_URI: nil))[0]
    assert_equal 1, @fetches
  end

  def test_healthcheck_exemption_uses_exact_target_method_and_real_peer
    good = env_for(nil, target: '/healthcheck', REMOTE_ADDR: '127.0.0.1')
    assert_equal 200, @guard.call(good.dup)[0]
    assert_equal 200, @guard.call(good.merge('REMOTE_ADDR' => '::1', 'REQUEST_METHOD' => 'HEAD'))[0]
    [
      { 'REMOTE_ADDR' => '10.0.0.42', 'HTTP_X_FORWARDED_FOR' => '127.0.0.1' },
      { 'REQUEST_METHOD' => 'POST' }, { 'REQUEST_METHOD' => 'OPTIONS' },
      { 'REQUEST_URI' => '/healthcheck?' }, { 'QUERY_STRING' => 'x=1' },
      { 'REQUEST_URI' => '/healthcheck/../ttyd/0' }, { 'PATH_INFO' => '/ttyd/0' },
      { 'SCRIPT_NAME' => '/insight' }
    ].each do |changes|
      assert_equal 401, @guard.call(good.merge(changes))[0], changes.inspect
    end
  end

  def test_readiness_waits_for_startup_cutoff_and_restarts_reject_old_assertions
    token = assertion
    guard = make_guard
    health = env_for(nil, target: '/healthcheck', REMOTE_ADDR: '127.0.0.1')
    assert_equal 503, guard.call(health.dup)[0]
    advance(11)
    assert_equal 200, guard.call(health.dup)[0]
    assert_equal 401, guard.call(env_for(token))[0]
    assert_equal 200, guard.call(env_for)[0]
  end
end
