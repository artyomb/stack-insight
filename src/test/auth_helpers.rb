# frozen_string_literal: true

require 'minitest/autorun'
require 'securerandom'
require 'rack/mock'
require_relative '../insight_auth'

module AuthHelpers
  AUDIENCE = 'insight'

  def setup_auth
    @now, @mono = 1_800_000_000.25, 100.0
    @key = Ed25519::SigningKey.generate
    @kid = SecureRandom.hex(16)
    @fetches = 0
    @seen = []
    @downstream = ->(env) { @seen << env.dup; [200, { 'content-type' => 'text/plain' }, ['OK']] }
    @guard = make_guard
    advance(11)
  end

  def make_guard(app = @downstream, **options)
    InsightAuth.new(app, key_endpoint: 'http://auth.test/.well-known/auth-jwks.json', audience: AUDIENCE,
                    clock: -> { @now }, monotonic: -> { @mono },
                    fetch_jwks: -> { @fetches += 1; jwks }, **options)
  end

  def advance(seconds)
    @now += seconds
    @mono += seconds
  end

  def jwks
    JSON.generate(issuer: 'auth.test', keys: [{ kty: 'OKP', crv: 'Ed25519', alg: 'EdDSA', use: 'sig', kid: @kid,
                                             x: Base64.urlsafe_encode64(@key.verify_key.to_bytes, padding: false) }])
  end

  def assertion(target: '/private?a=1&a=2', method: 'GET', **changes)
    claims = { ver: 1, iss: 'auth.test', aud: AUDIENCE, sub: 'operator', role: '', iat: @now.floor,
               exp: @now.floor + 30, jti: SecureRandom.hex(16),
               request: { method:, target_sha256: Base64.urlsafe_encode64(Digest::SHA256.digest(target), padding: false) } }
    JWT.encode(claims.merge(changes), @key, 'EdDSA', kid: @kid, typ: 'authslim-request+jwt')
  end

  def env_for(token = assertion, target: '/private?a=1&a=2', method: 'GET', **extra)
    env = Rack::MockRequest.env_for(target, method:)
    env.merge!('REQUEST_URI' => target, 'REMOTE_ADDR' => '10.0.0.42', 'HTTP_X_AUTH_JWT' => token,
               'HTTP_X_AUTHSLIM' => 'authorized', 'HTTP_X_TOKEN' => '{"role":"admin"}')
    env.merge(extra.transform_keys(&:to_s))
  end
end
