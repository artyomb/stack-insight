# frozen_string_literal: true

require_relative 'auth_helpers'
require 'fileutils'
require 'net/http'
require 'open3'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'yaml'

# Uses the real producer code and the real Insight config.ru with harmless Docker/ttyd fixtures.
class InsightTraefikAuthTest < Minitest::Test
  include AuthHelpers
  # Generated independently with openssl passwd -apr1 -salt testSalt.
  PASSWORD_ENTRY = 'operator:$apr1$testSalt$pkUoUmk2A9Sly3H3KUGXG0'

  def test_full_stack_authentication
    skip 'Set TRAEFIK_BINARY and OAUTH_SLIM_SOURCE to run the integration' unless ENV['TRAEFIK_BINARY'] && ENV['OAUTH_SLIM_SOURCE']

    @src = File.expand_path('..', __dir__)
    @directory = Dir.mktmpdir('insight-traefik-auth-')
    @pids = []
    sockets = 4.times.map { TCPServer.new('127.0.0.1', 0) }
    @auth_port, @backend_port, @proxy_port, @terminal_port = sockets.map { |socket| socket.addr[1] }
    sockets.each(&:close)
    prepare_producer
    prepare_backend
    prepare_proxy

    # All real application entrypoints must reject before any Docker or terminal work.
    %w[/ /stack /inspect /restart /update /ttyd/fixture /ttyd/fixture/ws /logs_ws /metrics /favicon.ico /healthcheck?].each do |target|
      assert_equal '401', request(@backend_port, target).code, target
      assert_equal '401', request(@backend_port, target, headers: { 'X-AUTH-JWT' => 'forged', 'X-AuthSlim' => 'authorized' }).code, target
    end
    assert_equal '401', request(@backend_port, '/private', method: 'OPTIONS').code
    assert_equal '401', websocket(@backend_port, '/ttyd/fixture/ws'), 'direct terminal upgrade requires JWT'
    assert_equal '200', request(@backend_port, '/healthcheck').code
    assert_equal '302', request(@proxy_port, '/auth-fixture', cookie: false).code
    assert_equal '401', request(@proxy_port, '/auth-fixture', basic: false).code

    [['insight.test', ''], ['prefix.test', '/insight'], ['map.test', '/map/insight']].each do |host, prefix|
      [['/auth-fixture%2Fy?a=1&a=2', '/auth-fixture%2Fy?a=1&a=2'],
       ['/auth-fixture%2fy?a=+&a=%20', '/auth-fixture%2Fy?a=+&a=%20'], ['/auth-fixture?', '/auth-fixture?']].each do |suffix, expected|
        response = request(@proxy_port, "#{prefix}#{suffix}", host:, headers: {
          'X-AUTH-JWT' => 'caller-forged', 'X-Forwarded-Uri' => '/forged', 'X-Forwarded-Method' => 'POST'
        })
        assert_equal '200', response.code, "#{host} #{suffix}: #{response.body}"
        body = JSON.parse(response.body)
        assert_equal expected, body['target']
        assert_equal '', body.fetch('identity').fetch('role')
        assert_equal [], body.fetch('credentials')
        assert_nil response['X-AUTH-JWT']
      end
      assert_equal '200', request(@proxy_port, "#{prefix}/ttyd/fixture", host:).code
      assert_equal '101', websocket(@proxy_port, "#{prefix}/ttyd/fixture/ws", host:)
    end

    token = mint('/auth-fixture')
    assert_equal '200', request(@backend_port, '/auth-fixture', basic: false, cookie: false, headers: { 'X-AUTH-JWT' => token }).code
    assert_equal '401', request(@backend_port, '/auth-fixture', headers: { 'X-AUTH-JWT' => token }).code
    assert_equal '401', request(@backend_port, '/auth-fixture?changed=1', headers: { 'X-AUTH-JWT' => mint('/auth-fixture') }).code
    @completed = true
  ensure
    @pids&.reverse_each do |pid|
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    end
    @pids&.reverse_each do |pid|
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
    FileUtils.remove_entry(@directory) if @directory && @completed
  end

  private

  def request(port, target, host: 'insight.test', cookie: true, basic: true, headers: {}, method: 'GET')
    req = Net::HTTPGenericRequest.new(method, false, true, target)
    req['Host'] = host
    req['Cookie'] = "auth_token=#{@session_token}" if cookie
    req.basic_auth('operator', 'test-password') if basic
    headers.each { |key, value| req[key] = value }
    Net::HTTP.start('127.0.0.1', port, nil, open_timeout: 2, read_timeout: 5) { |client| client.request(req) }
  end

  def await_response(port, target, code)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
    loop do
      begin
        return if request(port, target).code == code
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
        nil
      end
      raise "Fixture did not become ready; logs: #{@directory}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def spawn_server(name, port, body, env = {})
    file = File.join(@directory, "#{name}.ru")
    File.write(file, body)
    child_env = {
      'BUNDLE_GEMFILE' => File.join(@src, 'Gemfile'), 'RACK_ENV' => 'test', 'SERVER_ENV' => 'test',
      'QUIET' => 'true', 'PERFORMANCE' => 'true', 'OTEL_SDK_DISABLED' => 'true',
      'OTEL_TRACES_EXPORTER' => 'none', 'OTEL_METRICS_EXPORTER' => 'none', 'OTEL_LOGS_EXPORTER' => 'none',
      'NATS_URL' => nil, 'OAUTH_SLIM_KEY_ENDPOINT' => nil, 'OAUTH_SLIM_AUDIENCE' => nil
    }.merge(env)
    @pids << Process.spawn(child_env, 'bundle', 'exec', 'rackup', file, '-s', 'falcon', '-o', '127.0.0.1', '-p', port.to_s,
                           chdir: @src, out: File.join(@directory, "#{name}.log"), err: [:child, :out])
  end

  def prepare_producer
    producer_src = File.join(ENV.fetch('OAUTH_SLIM_SOURCE'), 'src')
    # Copy auth code into the disposable fixture so session keys never touch the source checkout.
    FileUtils.cp_r(File.join(producer_src, 'auth'), @directory)
    key = Ed25519::SigningKey.generate
    File.write(File.join(@directory, 'signing_key'), key.to_bytes.unpack1('H*'))
    @session_token = JWT.encode({ sub: 'operator', role: '', exp: Time.now.to_i + 300 }, key, 'EdDSA')
    spawn_server('auth', @auth_port, <<~RUBY, 'AUTH_SCOPE' => 'auth.test', 'AUTH_JWT_ENABLED' => 'true', 'AUTH_VERIFY_KEY' => nil, 'USERS_DB_URL' => nil, 'USERS_YAML' => nil, 'TELEGRAM_AUTH_BOT' => nil)
      require 'logger'
      require 'sinatra/base'
      LOGGER = Logger.new(File::NULL)
      FORWARD_OAUTH_AUTH_URL = '/authorize'
      require #{File.join(@directory, 'auth/auth_forward').dump}
      class TestAuth < Sinatra::Base
        set :environment, :test
        helpers AuthForward
      end
      run TestAuth
    RUBY
    await_response(@auth_port, '/.well-known/auth-jwks.json', '200')
  end

  def prepare_backend
    spawn_server('terminal', @terminal_port, <<~RUBY)
      require 'async/websocket/adapters/rack'
      run lambda { |env|
        if Async::WebSocket::Adapters::Rack.websocket?(env)
          Async::WebSocket::Adapters::Rack.open(env, protocols: ['tty']) { |connection| connection.read }
        else
          [200, { 'content-type' => 'text/plain' }, ['terminal fixture']]
        end
      }
    RUBY
    await_response(@terminal_port, '/', '200')
    spawn_server('insight', @backend_port, <<~RUBY, 'OAUTH_SLIM_KEY_ENDPOINT' => "http://127.0.0.1:#{@auth_port}/.well-known/auth-jwks.json", 'OAUTH_SLIM_AUDIENCE' => AUDIENCE)
      require 'rack/builder'
      app = Rack::Builder.parse_file(#{File.join(@src, 'config.ru').dump})
      ServerInsight.helpers do
        def docker(*) = Struct.new(:wait).new({ 'Name' => 'fixture' })
      end
      ServerTtyd.helpers do
        def start_session(*) = { port: #{@terminal_port} }
      end
      ServerInsight.get %r{/auth-fixture.*} do
        content_type :json
        JSON.generate(target: env['REQUEST_URI'], identity: env['oauth_slim.identity'],
          credentials: %w[HTTP_AUTHORIZATION HTTP_COOKIE HTTP_X_AUTH_JWT HTTP_X_AUTHSLIM HTTP_X_TOKEN].select { |name| env.key?(name) })
      end
      run app
    RUBY
    await_response(@backend_port, '/healthcheck', '200')
  end

  def prepare_proxy
    middlewares = { 'basic' => { 'basicAuth' => { 'users' => [PASSWORD_ENTRY] } } }
    routers = {}
    [['host', 'insight.test', ''], ['prefix', 'prefix.test', '/insight'], ['map', 'map.test', '/map/insight']].each do |name, host, prefix|
      middlewares["auth-#{name}"] = { 'forwardAuth' => {
        'address' => "http://127.0.0.1:#{@auth_port}/auth/assertion?#{URI.encode_www_form(aud: AUDIENCE, strip_prefix: prefix)}",
        'authResponseHeadersRegex' => '^X-'
      } }
      chain = ["auth-#{name}", 'basic']
      unless prefix.empty?
        middlewares["rewrite-#{name}"] = { 'replacePathRegex' => { 'regex' => "^#{prefix}(.*)", 'replacement' => '$1' } }
        chain << "rewrite-#{name}"
      end
      routers[name] = { 'rule' => "Host(#{host.dump})", 'service' => 'insight', 'middlewares' => chain }
    end
    file = File.join(@directory, 'traefik.yml')
    File.write(file, YAML.dump('http' => { 'routers' => routers, 'middlewares' => middlewares,
      'services' => { 'insight' => { 'loadBalancer' => { 'servers' => [{ 'url' => "http://127.0.0.1:#{@backend_port}" }] } } } }))
    @pids << Process.spawn(ENV.fetch('TRAEFIK_BINARY'), "--entrypoints.web.address=127.0.0.1:#{@proxy_port}",
                           '--entrypoints.web.forwardedheaders.insecure=true', '--entrypoints.web.http.encodedcharacters.allowencodedslash=true',
                           "--providers.file.filename=#{file}", '--log.level=ERROR',
                           out: File.join(@directory, 'traefik.log'), err: [:child, :out])
    await_response(@proxy_port, '/auth-fixture', '200')
  end

  def mint(target)
    response = request(@auth_port, "/auth/assertion?aud=#{AUDIENCE}", headers: {
      'X-Forwarded-Method' => 'GET', 'X-Forwarded-Uri' => target, 'X-Forwarded-Host' => 'insight.test'
    })
    assert_equal '200', response.code
    response['X-AUTH-JWT']
  end

  def websocket(port, target, host: 'insight.test')
    socket = TCPSocket.new('127.0.0.1', port)
    socket.write("GET #{target} HTTP/1.1\r\nHost: #{host}\r\nCookie: auth_token=#{@session_token}\r\nAuthorization: Basic #{Base64.strict_encode64('operator:test-password')}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: tty\r\n\r\n")
    Timeout.timeout(5) { socket.gets("\r\n").split(' ')[1] }
  ensure
    socket&.close
  end
end
