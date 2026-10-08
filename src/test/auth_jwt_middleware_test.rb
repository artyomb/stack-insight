# frozen_string_literal: true

require_relative 'auth_helpers'

class AuthJwtMiddlewareTest < Minitest::Test
  include AuthHelpers

  def setup = setup_auth

  def validator(**options)
    OAuthSlim::AuthJwtMiddleware.new(@downstream, audience: AUDIENCE, key_endpoint: 'http://auth.test/keys',
                                    authorize: ->(*) { true }, clock: -> { @now }, monotonic: -> { @mono },
                                    fetch_jwks: -> { jwks }, **options)
  end

  def test_copied_reference_has_no_local_modifications
    assert_equal '61ef36829bfa2cc24707a433341be9a9e6e8900ddf5e336e4765ff276cef05f8',
                 Digest::SHA256.file(File.expand_path('../auth_jwt_middleware.rb', __dir__)).hexdigest
  end

  def test_cache_capacity_never_evicts_live_assertions
    guard = validator(capacity: 1)
    advance(11)
    consumed, fresh = assertion, assertion
    assert_equal 200, guard.call(env_for(consumed))[0]
    assert_equal 503, guard.call(env_for(fresh))[0]
    assert_equal 401, guard.call(env_for(consumed))[0]
    advance(36)
    assert_equal 200, guard.call(env_for)[0]
  end

  def test_concurrent_replays_dispatch_only_once
    guard = validator
    advance(11)
    token = assertion
    codes = 12.times.map { Thread.new { guard.call(env_for(token))[0] } }.map(&:value)
    assert_equal 1, codes.count(200)
    assert_equal 11, codes.count(401)
  end

  def test_expired_long_lived_future_and_prestartup_assertions_fail
    [
      { iat: @now.floor - 40, exp: @now.floor - 10 },
      { exp: @now.floor + 31 }, { iat: @now.floor + 10 }, { iat: @now.floor - 12 },
      { iat: @now }, { nbf: @now.floor }, { jti: 'not-a-random-id' }
    ].each { |claims| assert_equal 401, @guard.call(env_for(assertion(**claims)))[0], claims.inspect }
  end

  def test_key_failure_fails_closed
    guard = validator(fetch_jwks: -> { raise OAuthSlim::AuthJwtMiddleware::Unavailable })
    advance(11)
    assert_equal 503, guard.call(env_for)[0]
    assert_empty @seen
  end

  def test_jwks_cache_refreshes_rotated_keys_after_cooldown
    assert_equal 200, @guard.call(env_for)[0]
    @key, @kid = Ed25519::SigningKey.generate, SecureRandom.hex(16)
    assert_equal 503, @guard.call(env_for)[0]
    advance(5)
    assert_equal 200, @guard.call(env_for)[0]
  end

  def test_duplicate_json_members_and_algorithm_confusion_fail
    token = assertion
    header, claims, = token.split('.')
    duplicate = Base64.urlsafe_encode64(Base64.urlsafe_decode64(header).sub('{', '{"alg":"HS256",'), padding: false)
    assert_equal 401, @guard.call(env_for("#{duplicate}.#{claims}.AA"))[0]
    hmac = JWT.encode(JSON.parse(Base64.urlsafe_decode64(claims)), @key.verify_key.to_bytes, 'HS256', kid: @kid, typ: 'authslim-request+jwt')
    assert_equal 401, @guard.call(env_for(hmac))[0]
    duplicate_claims = Base64.urlsafe_encode64(Base64.urlsafe_decode64(claims).sub('{', '{"aud":"other",'), padding: false)
    payload = "#{header}.#{duplicate_claims}"
    signature = Base64.urlsafe_encode64(@key.sign(payload), padding: false)
    assert_equal 401, @guard.call(env_for("#{payload}.#{signature}"))[0]
  end

  def test_forked_validator_rejects_until_reset_and_new_startup_cutoff
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(@guard.call(env_for)[0].to_s)
      writer.close
      exit! 0
    end
    writer.close
    assert_equal '503', reader.read
    Process.wait(pid)
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_clock_rollback_cannot_resurrect_expired_assertions
    token = assertion
    advance(36)
    assert_equal 401, @guard.call(env_for(token))[0]
    @now -= 36
    assert_equal 401, @guard.call(env_for(token))[0]
  end
end
