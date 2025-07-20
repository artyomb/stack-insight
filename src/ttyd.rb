require 'sinatra/base'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'open3'

class ServerTtyd < Sinatra::Base
  TTYD_SESSIONS = {}
  PORT_RANGE = (8000..8010).freeze

  helpers do
    def available_port
      PORT_RANGE.find { |port| !port_in_use?(port) } ||
        raise('No available ports in range 8000-8010')
    end

    def port_in_use?(port)
      TTYD_SESSIONS.values.any? { |session| session[:port] == port }
    end

    def shell_for_container(cid)
      system("docker exec #{cid} ls /bin/bash") ? 'bash' : 'sh'
    end

    def cleanup_dead_sessions
      TTYD_SESSIONS.delete_if do |_, session|
        !session[:thread]&.alive? || !process_running?(session[:port])
      end
    end

    def process_running?(port)
      system("pgrep -f 'ttyd.*#{port}'", out: File::NULL, err: File::NULL)
    end

    def start_ttyd_session(cid)
      cleanup_dead_sessions

      return TTYD_SESSIONS[cid] if TTYD_SESSIONS[cid]&.dig(:thread)&.alive?

      port = available_port
      shell = shell_for_container(cid)

      thread = Thread.new { run_ttyd_process(cid, port, shell) }

      session = { thread:, port:, cid: }
      TTYD_SESSIONS[cid] = session

      sleep 0.5 # Allow ttyd to start

      session[:thread].alive? ? session :
        (TTYD_SESSIONS.delete(cid); raise("Failed to start ttyd for #{cid}"))
    end

    private

    def run_ttyd_process(cid, port, shell)
      cmd = "ttyd -p #{port} -W docker exec -it #{cid} #{shell}"

      Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        # Log output in background
        Thread.new { stdout.each_line { |line| puts "[ttyd-#{cid}] #{line}" } }
        Thread.new { stderr.each_line { |line| puts "[ttyd-#{cid}] ERROR: #{line}" } }

        wait_thr.join
        puts "ttyd process for #{cid} exited with code #{wait_thr.value.exitstatus}"
      end
    ensure
      TTYD_SESSIONS.delete(cid)
    end
  end

  get '/ttyd/:cid/ws' do
    session = start_ttyd_session(params[:cid])

    return unless Async::WebSocket::Adapters::Rack.websocket?(env)

    protocols = env['HTTP_SEC_WEBSOCKET_PROTOCOL']&.split(',')&.map(&:strip) || []
    selected = protocols.include?('tty') ? ['tty'] : []

    Async::WebSocket::Adapters::Rack.open(env, protocols: selected) do |client|
      proxy_websocket_connection(client, session[:port])
    end
  rescue => e
    puts "WebSocket error for #{params[:cid]}: #{e.message}"
  end

  get '/ttyd/:cid*' do
    session = start_ttyd_session(params[:cid])
    path = params['splat'].first.split('/').last

    proxy_http_request(session[:port], path)
  rescue => e
    puts "HTTP proxy error for #{params[:cid]}: #{e.message}"
    halt 500, "Internal server error"
  end

  private

  def proxy_websocket_connection(client, port)
    endpoint = Async::HTTP::Endpoint.parse("ws://localhost:#{port}/ws")

    Async::WebSocket::Client.connect(endpoint, protocols: ['tty']) do |ttyd_ws|
      # Bidirectional message proxying
      tasks = [
        Async { proxy_messages(ttyd_ws, client) },
        Async { proxy_messages(client, ttyd_ws) }
      ]

      tasks.each(&:wait)
    end
  rescue => e
    puts "WebSocket proxy error: #{e.message}"
  ensure
    client.close rescue nil
  end

  def proxy_messages(from, to)
    while message = from.read
      to.write(message)
      to.flush
    end
  rescue => e
    puts "Message proxy error: #{e.message}"
  ensure
    to.close rescue nil
  end

  def proxy_http_request(port, path)
    uri = URI("http://localhost:#{port}/#{path}")
    response = Net::HTTP.get_response(uri)

    content_type response['content-type'] if response['content-type']
    status response.code.to_i
    response.body
  end
end