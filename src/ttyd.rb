# frozen_string_literal: true

require 'sinatra/base'
require 'async/barrier'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'open3'
require 'socket'

class ServerTtyd < Sinatra::Base
  SESSIONS = {}
  SESSIONS_MUTEX = Mutex.new
  PORTS = (8000..8010).freeze
  SESSION_START_TIMEOUT = Float(ENV.fetch('TTYD_SESSION_START_TIMEOUT', 30))
  CONTAINER_REF = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/

  helpers do
    def find_port
      reserved = SESSIONS.values.filter_map { _1[:port] if _1[:thread]&.alive? }
      PORTS.find { !reserved.include?(_1) && port_free?(_1) } || raise('No ports available')
    end

    def port_free?(port) = (TCPServer.new('127.0.0.1', port).close; true) rescue false

    def container_running?(cid) = system('docker', 'exec', cid, 'true', out: File::NULL, err: File::NULL)

    def container_shell(cid)
      system('docker', 'exec', cid, 'test', '-x', '/bin/bash', out: File::NULL, err: File::NULL) ? 'bash' : 'sh'
    end

    def nt_mapping = ENV.fetch('NT_MAPPING', 'htop:htop').split(':', 2)

    def cleanup_sessions
      stale = SESSIONS_MUTEX.synchronize do
        SESSIONS.values.reject { _1[:thread]&.alive? }.each { SESSIONS.delete(_1[:cid]) }
      end

      stale.each { terminate_session(_1) }
    end

    def start_session(cid)
      raise "Invalid container reference: #{cid}" unless CONTAINER_REF.match?(cid)

      name, = nt_mapping
      raise "Container #{cid} not running" unless cid == name || container_running?(cid)

      cleanup_sessions
      session = reusable_session(cid)
      return session if session

      shell = container_shell(cid) unless cid == name
      wait_for_ttyd(create_session(cid, shell))
    end

    private

    def reusable_session(cid)
      SESSIONS_MUTEX.synchronize do
        session = SESSIONS[cid]
        return unless session&.dig(:thread)&.alive?

        session[:last_access] = monotonic_time
        session
      end
    end

    def create_session(cid, shell)
      SESSIONS_MUTEX.synchronize do
        current = SESSIONS[cid]
        if current&.dig(:thread)&.alive?
          current[:last_access] = monotonic_time
          next current
        end

        session = { cid:, port: find_port, connected: false, last_access: monotonic_time }
        SESSIONS[cid] = session
        session[:thread] = Thread.new { run_ttyd(session, shell) }
        session[:watchdog] = Thread.new { expire_unconnected_session(session) }
        session
      end
    end

    def wait_for_ttyd(session)
      20.times do |i|
        if current_session?(session) && session[:thread]&.alive? && !port_free?(session[:port])
          puts "ttyd started for #{session[:cid]} on port #{session[:port]} after #{i * 0.1}s"
          return session
        end
        sleep 0.1
      end

      stop_session(session)
      raise "ttyd startup failed for #{session[:cid]}"
    end

    def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def current_session?(session)
      SESSIONS_MUTEX.synchronize { SESSIONS[session[:cid]].equal?(session) }
    end

    def remove_session(session)
      SESSIONS_MUTEX.synchronize do
        SESSIONS.delete(session[:cid]) if SESSIONS[session[:cid]].equal?(session)
      end
    end

    def stop_session(session)
      remove_session(session)
      terminate_session(session)
    end

    def terminate_session(session)
      begin
        Process.kill('TERM', session[:pid]) if session[:pid]
      rescue Errno::ESRCH
        nil
      end

      [session[:thread], session[:watchdog]].compact.each do |thread|
        thread.kill unless thread.equal?(Thread.current)
      end
    end

    def expire_unconnected_session(session)
      loop do
        remaining = SESSIONS_MUTEX.synchronize do
          return unless SESSIONS[session[:cid]].equal?(session)
          return if session[:connected]

          SESSION_START_TIMEOUT - (monotonic_time - session[:last_access])
        end

        if remaining <= 0
          puts "ttyd[#{session[:cid]}] stopped after no WebSocket connected"
          stop_session(session)
          return
        end

        sleep remaining
      end
    end

    def mark_connected(session)
      SESSIONS_MUTEX.synchronize do
        return unless SESSIONS[session[:cid]].equal?(session)

        session[:connected] = true
      end
    end

    def ttyd_command(session, shell)
      name, value = nt_mapping
      command = if session[:cid] == name
                  ['/bin/sh', '-c', value]
                else
                  ['docker', 'exec', '-it', session[:cid], shell]
                end
      ['ttyd', '-i', 'lo', '-p', session[:port].to_s, '-W', '--exit-no-conn', *command]
    end

    def run_ttyd(session, shell)
      Open3.popen3(*ttyd_command(session, shell)) do |stdin, stdout, stderr, wait|
        session[:pid] = wait.pid
        stdin.close

        [
          Thread.new { stdout.each_line { puts "[#{session[:cid]}] #{_1.chomp}" } },
          Thread.new { stderr.each_line { puts "[#{session[:cid]}] ERR: #{_1.chomp}" } }
        ].each(&:join)

        puts "ttyd[#{session[:cid]}] exit: #{wait.value.exitstatus}"
      end
    rescue StandardError => e
      warn "ttyd[#{session[:cid]}] failed: #{e.message}"
    ensure
      remove_session(session)
      session[:watchdog]&.kill unless session[:watchdog].equal?(Thread.current)
    end

    def bridge_websockets(client, ttyd)
      barrier = Async::Barrier.new
      barrier.async { forward_websocket(ttyd, client) }
      barrier.async { forward_websocket(client, ttyd) }
      barrier.wait do |task|
        task.wait
        break
      end
    ensure
      barrier&.stop
    end

    def forward_websocket(source, target)
      while (message = source.read)
        target.write(message)
        target.flush
      end
    rescue StandardError
      nil
    end

    def close_websocket(socket)
      socket&.close
    rescue StandardError
      nil
    end
  end

  get '/ttyd/:cid/ws' do
    client = ttyd = nil
    session = start_session(params[:cid])
    return unless Async::WebSocket::Adapters::Rack.websocket?(env)

    protocols = env['HTTP_SEC_WEBSOCKET_PROTOCOL']&.split(',')&.map(&:strip) || []
    selected = protocols.include?('tty') ? ['tty'] : []

    Async::WebSocket::Adapters::Rack.open(env, protocols: selected) do |connection|
      client = connection
      endpoint = Async::HTTP::Endpoint.parse("ws://127.0.0.1:#{session[:port]}/ws")

      Async::WebSocket::Client.connect(endpoint, protocols: ['tty']) do |connection|
        ttyd = connection
        mark_connected(session)
        bridge_websockets(client, ttyd)
      end
    end
  rescue StandardError => e
    puts "WS[#{params[:cid]}]: #{e.message}"
    halt 400, "Container not available: #{e.message}"
  ensure
    close_websocket(ttyd)
    close_websocket(client)
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
    rescue StandardError => e # Errno::ECONNREFUSED
      puts "HTTP[#{params[:cid]}]: #{e.message}"
      sleep 0.2
    end

    halt 503
  rescue StandardError => e
    puts "HTTP[#{params[:cid]}]: #{e.message}"
    halt 400, "Container not available: #{e.message}"
  end
end
