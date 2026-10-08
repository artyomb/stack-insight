# frozen_string_literal: true

# Copy this file unchanged into a single-process Rack consumer. See docs/auth-jwt.md.
require 'base64'
require 'digest'
require 'ed25519'
gem 'json', '>= 2.18'
require 'json'
require 'jwt'
require 'jwt/eddsa'
require 'uri'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'

module OAuthSlim
  class AuthJwtMiddleware
    VERSION = 1
    TYPE = 'authslim-request+jwt'
    MAX_TOKEN_BYTES = 8192
    MAX_JWKS_BYTES = 65_536
    KID = /\A[0-9a-f]{32}\z/
    AUDIENCE = /\A[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}\z/
    LEGACY_HEADERS = %w[HTTP_X_AUTHSLIM HTTP_X_TOKEN HTTP_X_ACCESS_TOKEN].freeze

    class Invalid < StandardError; end
    class Unavailable < StandardError; end
    class Forbidden < StandardError; end

    class KeyEndpoint
      def initialize(url)
        uri = URI.parse(url)
        unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.fragment
          raise ArgumentError, 'Invalid key endpoint'
        end
        @connection = Faraday.new(url:, proxy: nil, ssl: { verify: true },
                                  request: { timeout: 15, open_timeout: 10 }) do |connection|
          connection.request :retry, max: 2, interval: 0.2, backoff_factor: 2
          connection.adapter :net_http_persistent, pool_size: 10 do |http|
            http.idle_timeout = 60
          end
        end
      rescue URI::InvalidURIError
        raise ArgumentError, 'Invalid key endpoint'
      end

      def call
        body = +''
        response = @connection.get do |request|
          request.headers['Accept'] = 'application/json'
          request.options.on_data = lambda do |chunk, total, _env|
            body.clear if total == chunk.bytesize
            raise Unavailable, 'Key response too large' if total > MAX_JWKS_BYTES || body.bytesize + chunk.bytesize > MAX_JWKS_BYTES

            body << chunk
          end
        end
        raise Unavailable, 'Key endpoint failed' unless response.status == 200

        body
      rescue Faraday::Error
        raise Unavailable, 'Key endpoint unavailable'
      end
    end

    class KeyCache
      def initialize(fetch:, monotonic:, issuer:, ttl: 30, refresh_interval: 5)
        @fetch, @monotonic, @issuer, @ttl, @refresh_interval = fetch, monotonic, issuer, ttl, refresh_interval
        @mutex = Mutex.new
        @keys, @negative = {}, {}
        @expires_at = @retry_at = -Float::INFINITY
      end

      def lookup(kid)
        @mutex.synchronize do
          now = @monotonic.call
          return [@keys[kid], @snapshot_issuer] if now < @expires_at && @keys.key?(kid)
          raise Invalid, 'Unknown signing key' if now < @expires_at && @negative.fetch(kid, 0) > now
          raise Unavailable, 'Key refresh rate limited' if now < @retry_at

          @retry_at = now + @refresh_interval
          refresh
          return [@keys[kid], @snapshot_issuer] if @keys.key?(kid)

          @negative[kid] = now + @refresh_interval
          raise Invalid, 'Unknown signing key'
        end
      end

      private

      def refresh
        body = @fetch.call
        raise Unavailable, 'Invalid key response' unless body.is_a?(String) && body.bytesize <= MAX_JWKS_BYTES

        data = JSON.parse(body, allow_duplicate_key: false, max_nesting: 8)
        issuer = data.is_a?(Hash) && data['issuer']
        keys = data.is_a?(Hash) && data['keys']
        unless issuer.is_a?(String) && issuer.bytesize.between?(1, 256) && !issuer.match?(/[\s[:cntrl:]]/) &&
               (@issuer.nil? || issuer == @issuer) && keys.is_a?(Array) && keys.size.between?(1, 8)
          raise Unavailable, 'Invalid key metadata'
        end
        parsed = keys.each_with_object({}) do |key, result|
          unless key.is_a?(Hash) && key['kty'] == 'OKP' && key['crv'] == 'Ed25519' &&
                 key['alg'] == 'EdDSA' && key['use'] == 'sig' && !key.key?('d') &&
                 key['kid'].is_a?(String) && KID.match?(key['kid']) && !result.key?(key['kid']) &&
                 key['x'].is_a?(String) && key['x'].match?(/\A[A-Za-z0-9_-]{43}\z/)
            raise Unavailable, 'Invalid public key'
          end
          bytes = Base64.urlsafe_decode64(key['x'])
          unless bytes.bytesize == 32 && Base64.urlsafe_encode64(bytes, padding: false) == key['x']
            raise Unavailable, 'Invalid public key'
          end
          result[key['kid']] = Ed25519::VerifyKey.new(bytes)
        end
        @keys, @snapshot_issuer = parsed, issuer
        @expires_at = @monotonic.call + @ttl
        @negative.clear
      rescue JSON::ParserError, ArgumentError, Invalid
        raise Unavailable, 'Invalid key response'
      end
    end

    # A timing wheel avoids scanning the entire replay cache on every request.
    class ReplayCache
      def initialize(capacity:)
        @capacity, @entries, @buckets = capacity, {}, {}
        @last_cleanup = nil
        @mutex = Mutex.new
      end

      def consume(key, deadline, now)
        @mutex.synchronize do
          cleanup(now.floor)
          raise Invalid, 'Assertion already consumed' if @entries.key?(key)
          raise Unavailable, 'Replay cache full' if @entries.size >= @capacity

          @entries[key] = deadline
          (@buckets[deadline.ceil] ||= []) << key
        end
      end

      private

      def cleanup(second)
        if @last_cleanup.nil? || second - @last_cleanup > 120
          @buckets.keys.select { |deadline| deadline <= second }.each { |deadline| expire(deadline) }
        elsif second > @last_cleanup
          ((@last_cleanup + 1)..second).each { |deadline| expire(deadline) }
        end
        @last_cleanup = second
      end

      def expire(deadline)
        @buckets.delete(deadline)&.each { |key| @entries.delete(key) }
      end
    end

    def initialize(app, audience:, key_endpoint:, authorize:, issuer: nil, capacity: 10_000,
                   max_lifetime: 30, leeway: 5, clock: -> { Time.now.to_f },
                   monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, fetch_jwks: nil)
      raise ArgumentError, 'Invalid audience' unless audience.is_a?(String) && AUDIENCE.match?(audience)
      raise ArgumentError, 'Authorization policy required' unless authorize.respond_to?(:call)
      raise ArgumentError, 'Invalid replay capacity' unless capacity.is_a?(Integer) && capacity.between?(1, 1_000_000)
      raise ArgumentError, 'Invalid maximum lifetime' unless max_lifetime.is_a?(Integer) && max_lifetime.between?(1, 60)
      raise ArgumentError, 'Invalid clock tolerance' unless leeway.is_a?(Integer) && leeway.between?(0, 5)
      if issuer && (!issuer.is_a?(String) || !issuer.bytesize.between?(1, 256) || issuer.match?(/[\s[:cntrl:]]/))
        raise ArgumentError, 'Invalid issuer pin'
      end

      @app, @audience, @authorize, @issuer = app, audience, authorize, issuer
      @capacity, @max_lifetime, @leeway = capacity, max_lifetime, leeway
      @clock, @monotonic = clock, monotonic
      @fetch = fetch_jwks || KeyEndpoint.new(key_endpoint)
      reset_process_state!
    end

    # Invoke in an after-fork hook before readiness if the Rack app was preloaded.
    def reset_process_state!
      @pid = Process.pid
      @time_mutex = Mutex.new
      @wall_anchor, @mono_anchor = @clock.call, @monotonic.call
      @minimum_iat = (@wall_anchor + @leeway).floor + 1
      @keys = KeyCache.new(fetch: @fetch, monotonic: @monotonic, issuer: @issuer)
      @replays = ReplayCache.new(capacity: @capacity)
    end

    def call(env)
      token = env.delete('HTTP_X_AUTH_JWT')
      LEGACY_HEADERS.each { |name| env.delete(name) }
      env.delete('oauth_slim.identity')
      begin
        raise Unavailable, 'Validator requires after-fork initialization' if Process.pid != @pid

        claims = verify(token, env)
        identity = claims.slice('iss', 'aud', 'sub', 'role').transform_values(&:freeze).freeze
        raise Forbidden, 'Forbidden' unless @authorize.call(identity, env)

        now = validation_time
        raise Invalid, 'Assertion expired' unless claims['exp'] + @leeway > now

        @replays.consume([claims['iss'], claims['aud'], claims['jti']], claims['exp'] + @leeway, now)
        env['oauth_slim.identity'] = identity
      rescue Invalid, JWT::DecodeError, JSON::ParserError, ArgumentError
        return failure(401, 'Unauthorized')
      rescue Forbidden
        return failure(403, 'Forbidden')
      rescue Unavailable
        return failure(503, 'Authentication unavailable')
      end
      @app.call(env)
    end

    private

    def verify(token, env)
      unless token.is_a?(String) && token.bytesize.between?(1, MAX_TOKEN_BYTES) &&
             token.match?(/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
        raise Invalid, 'Invalid assertion'
      end
      encoded_header, encoded_claims, = token.split('.')
      header = JSON.parse(Base64.urlsafe_decode64(encoded_header), allow_duplicate_key: false, max_nesting: 8)
      unless header.is_a?(Hash) && header.keys.sort == %w[alg kid typ] &&
             header['alg'] == 'EdDSA' && header['typ'] == TYPE && header['kid'].is_a?(String) && KID.match?(header['kid'])
        raise Invalid, 'Invalid assertion header'
      end
      key, issuer = @keys.lookup(header['kid'])
      JWT.decode(token, key, true, algorithm: 'EdDSA', verify_expiration: false, verify_not_before: false)
      claims = JSON.parse(Base64.urlsafe_decode64(encoded_claims), allow_duplicate_key: false, max_nesting: 8)
      validate_claims(claims, issuer, env)
      claims
    end

    def validate_claims(claims, issuer, env)
      unless claims.is_a?(Hash) && claims['ver'].is_a?(Integer) && claims['ver'] == VERSION &&
             claims['iss'] == issuer && claims['aud'] == @audience &&
             claims['sub'].is_a?(String) && claims['sub'].bytesize.between?(1, 256) && !claims['sub'].strip.empty? &&
             claims['role'].is_a?(String) && claims['role'].bytesize <= 128 &&
             claims['jti'].is_a?(String) && KID.match?(claims['jti'])
        raise Invalid, 'Invalid claims'
      end
      now = validation_time
      issued, expiry = claims.values_at('iat', 'exp')
      unless issued.is_a?(Integer) && expiry.is_a?(Integer) && issued >= @minimum_iat &&
             issued <= now + @leeway && expiry > issued && expiry <= issued + @max_lifetime && expiry + @leeway > now
        raise Invalid, 'Invalid assertion lifetime'
      end
      raise Invalid, 'Unsupported not-before claim' if claims.key?('nbf')

      target = env['REQUEST_URI']
      operation = claims['request']
      unless target.is_a?(String) && target.bytesize <= 16_384 && target.start_with?('/') &&
             !target.match?(/[#\s[:cntrl:]]/) && operation.is_a?(Hash) &&
             operation['method'].is_a?(String) && operation['method'] == env['REQUEST_METHOD'] &&
             operation['target_sha256'] == Base64.urlsafe_encode64(Digest::SHA256.digest(target), padding: false)
        raise Invalid, 'Request does not match'
      end
    end

    def validation_time
      @time_mutex.synchronize do
        mono = @monotonic.call
        @wall_anchor = [@clock.call, @wall_anchor + mono - @mono_anchor].max
        @mono_anchor = mono
        @wall_anchor
      end
    end

    def failure(status, message)
      [status, { 'content-type' => 'text/plain', 'cache-control' => 'no-store' }, [message]]
    end
  end
end
