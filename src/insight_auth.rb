# frozen_string_literal: true

require_relative 'auth_jwt_middleware'

# Keep the copied assertion validator separate from Insight's deployment policy.
class InsightAuth
  SETTINGS = %w[OAUTH_SLIM_KEY_ENDPOINT OAUTH_SLIM_AUDIENCE].freeze
  STARTUP_DELAY = 11

  def self.options(env = ENV)
    return unless SETTINGS.any? { |name| env.key?(name) }

    SETTINGS.each do |name|
      raise ArgumentError, "#{name} is required when Insight authentication is configured" if env[name].to_s.strip.empty?
    end
    { key_endpoint: env.fetch('OAUTH_SLIM_KEY_ENDPOINT'), audience: env.fetch('OAUTH_SLIM_AUDIENCE') }
  end

  def initialize(app, key_endpoint:, audience:, clock: -> { Time.now.to_f },
                 monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, fetch_jwks: nil)
    @app, @monotonic, @pid = app, monotonic, Process.pid
    @ready_at = monotonic.call + STARTUP_DELAY
    sanitized = lambda do |env|
      env.delete('HTTP_AUTHORIZATION')
      env.delete('HTTP_COOKIE')
      app.call(env)
    end
    @protected = OAuthSlim::AuthJwtMiddleware.new(sanitized, key_endpoint:, audience:, clock:, monotonic:, fetch_jwks:,
                                                 authorize: ->(_identity, _env) { true })
  end

  def call(env)
    if loopback_healthcheck?(env)
      return [503, { 'content-type' => 'text/plain', 'cache-control' => 'no-store' }, ['Authentication starting']] unless
        Process.pid == @pid && @monotonic.call >= @ready_at

      # This exact route continues through the framework's existing healthcheck.
      %w[HTTP_AUTHORIZATION HTTP_COOKIE HTTP_X_AUTH_JWT HTTP_X_AUTHSLIM HTTP_X_TOKEN HTTP_X_ACCESS_TOKEN].each { |key| env.delete(key) }
      return @app.call(env)
    end

    @protected.call(env)
  end

  private

  def loopback_healthcheck?(env)
    %w[127.0.0.1 ::1].include?(env['REMOTE_ADDR']) && %w[GET HEAD].include?(env['REQUEST_METHOD']) &&
      env['REQUEST_URI'] == '/healthcheck' && env['PATH_INFO'] == '/healthcheck' &&
      env['SCRIPT_NAME'].to_s.empty? && env['QUERY_STRING'].to_s.empty?
  end
end
