require 'sinatra/base'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'open3'
require 'socket'

class ServerTtyd < Sinatra::Base
  SESSIONS = {}
  PORTS = (8000..8010).freeze

  helpers do
    def find_port = PORTS.find { port_free?(_1) } || raise('No ports available')

    def port_free?(port) = (TCPServer.new('127.0.0.1', port).close; true) rescue false

    def container_running?(cid) = system("docker exec #{cid} echo test", out: File::NULL, err: File::NULL)

    def container_shell(cid) = system("docker exec #{cid} ls /bin/bash", out: File::NULL, err: File::NULL) ? 'bash' : 'sh'

    def cleanup_sessions = SESSIONS.filter! { |_, s| s[:thread]&.alive? || (kill_session(s); false) }

    def kill_session(session) = (Process.kill('TERM', session[:pid]) if session[:pid]; session[:thread]&.kill) rescue nil

    def start_session(cid)
      raise "Container #{cid} not running" unless cid == '0' || container_running?(cid)

      cleanup_sessions
      return SESSIONS[cid] if SESSIONS[cid]&.dig(:thread)&.alive?

      kill_session(SESSIONS[cid]) if SESSIONS[cid]

      port, shell = find_port, container_shell(cid)
      SESSIONS[cid] = { thread: Thread.new { run_ttyd(cid, port, shell) }, port:, cid: }

      20.times do |i|
        if SESSIONS[cid] && SESSIONS[cid][:thread]&.alive? && !port_free?(port)
          puts "ttyd started for #{cid} on port #{port} after #{i * 0.1}s"
          return SESSIONS[cid]
        end
        sleep 0.1
      end

      kill_session(SESSIONS[cid])
      SESSIONS.delete(cid)
      raise "ttyd startup failed for #{cid}"
    end

    private

    def run_ttyd(cid, port, shell)
      host_shell = 'docker run --rm -it --privileged --pid=host alpine:edge nsenter -t 1 -m -u -n -i sh'
      cmd = cid == '0' ? host_shell : "docker exec -it #{cid} #{shell}"
      cmd = "ttyd -p #{port} -W #{cmd}"
      Open3.popen3(cmd) do |stdin, stdout, stderr, wait|
        SESSIONS[cid][:pid] = wait.pid if SESSIONS[cid]
        stdin.close

        [
          Thread.new { stdout.each_line { puts "[#{cid}] #{_1.chomp}" } },
          Thread.new { stderr.each_line { puts "[#{cid}] ERR: #{_1.chomp}" } }
        ].each(&:join)

        puts "ttyd[#{cid}] exit: #{wait.value.exitstatus}"
      end
    ensure
      SESSIONS.delete(cid)
    end
  end

  get '/ttyd/:cid/ws' do
    session = start_session(params[:cid])
    return unless Async::WebSocket::Adapters::Rack.websocket?(env)

    protocols = env['HTTP_SEC_WEBSOCKET_PROTOCOL']&.split(',')&.map(&:strip) || []
    selected = protocols.include?('tty') ? ['tty'] : []

    Async::WebSocket::Adapters::Rack.open(env, protocols: selected) do |client|
      endpoint = Async::HTTP::Endpoint.parse("ws://127.0.0.1:#{session[:port]}/ws")

      Async::WebSocket::Client.connect(endpoint, protocols: ['tty']) do |ttyd|
        [
          Async { while msg = ttyd.read; client.write(msg); client.flush; end rescue nil },
          Async { while msg = client.read; ttyd.write(msg); ttyd.flush; end rescue nil }
        ].each(&:wait)
      end
    end
  rescue => e
    puts "WS[#{params[:cid]}]: #{e.message}"
    halt 400, "Container not available: #{e.message}"
  ensure
    client&.close rescue nil
  end

  get '/ttyd/:cid*' do
    session = start_session(params[:cid])
    path = params.dig('splat', 0)&.split('/')&.last || ''

    4.times do
      puts "connecting to http://127.0.0.1:#{session[:port]}/#{path}"

      uri = URI("http://127.0.0.1:#{session[:port]}/#{path}")
      response = Net::HTTP.get_response(uri)
      content_type response['content-type'] if response['content-type']
      status response.code.to_i
      return response.body
    rescue => e #Errno::ECONNREFUSED
      puts "HTTP[#{params[:cid]}]: #{e.message}"
      sleep 0.2
    end

    halt 503
  rescue => e
    puts "HTTP[#{params[:cid]}]: #{e.message}"
    halt 400, "Container not available: #{e.message}"
  end
end