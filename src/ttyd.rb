require 'sinatra/base'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'open3'
require 'socket'

class ServerTtyd < Sinatra::Base
  TTYD_SESSIONS = {}
  PORT_RANGE = (8000..8010).freeze

  helpers do
    def available_port
      PORT_RANGE.find { |port| port_available?(port) } ||
        raise('No available ports in range 8000-8010')
    end

    def port_available?(port)
      # Check if port is actually free on the system
      begin
        server = TCPServer.new('127.0.0.1', port)
        server.close
        true
      rescue Errno::EADDRINUSE
        false
      rescue => e
        puts "Port check error for #{port}: #{e.message}"
        false
      end
    end

    def shell_for_container(cid)
      system("docker exec #{cid} ls /bin/bash", out: File::NULL, err: File::NULL) ? 'bash' : 'sh'
    end

    def cleanup_dead_sessions
      TTYD_SESSIONS.delete_if do |cid, session|
        if !session[:thread]&.alive?
          puts "Cleaning up dead session for #{cid}"
          cleanup_session(session)
          true
        else
          false
        end
      end
    end

    def cleanup_session(session)
      if session[:process_pid]
        begin
          Process.kill('TERM', session[:process_pid])
          sleep 0.5
          Process.kill('KILL', session[:process_pid]) if process_exists?(session[:process_pid])
        rescue Errno::ESRCH
          # Process already dead
        rescue => e
          puts "Error killing process #{session[:process_pid]}: #{e.message}"
        end
      end

      session[:thread]&.kill rescue nil
    end

    def process_exists?(pid)
      Process.getpgid(pid)
      true
    rescue Errno::ESRCH
      false
    end

    def start_ttyd_session(cid)
      cleanup_dead_sessions

      # Return existing session if still alive
      if (session = TTYD_SESSIONS[cid]) && session[:thread]&.alive?
        return session
      end

      # Clean up any stale session
      cleanup_session(TTYD_SESSIONS[cid]) if TTYD_SESSIONS[cid]
      TTYD_SESSIONS.delete(cid)

      port = available_port
      shell = shell_for_container(cid)

      puts "Starting ttyd for container #{cid} on port #{port} with shell #{shell}"

      thread = Thread.new { run_ttyd_process(cid, port, shell) }

      session = { thread:, port:, cid: }
      TTYD_SESSIONS[cid] = session

      # Wait for ttyd to start and capture process info
      start_time = Time.now
      while Time.now - start_time < 5 # 5 second timeout
        if session[:process_pid] && port_in_use_by_system?(port)
          puts "ttyd successfully started for #{cid} on port #{port}"
          return session
        end
        sleep 0.1
      end

      # Startup failed
      cleanup_session(session)
      TTYD_SESSIONS.delete(cid)
      raise("Failed to start ttyd for #{cid} - timeout waiting for process")
    end

    def port_in_use_by_system?(port)
      !port_available?(port)
    end

    private

    def run_ttyd_process(cid, port, shell)
      cmd = "ttyd -p #{port} -W docker exec -it #{cid} #{shell}"

      Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
        # Store process info in session
        TTYD_SESSIONS[cid][:process_pid] = wait_thr.pid if TTYD_SESSIONS[cid]

        stdin.close

        # Create output threads that won't block
        stdout_thread = Thread.new do
          begin
            stdout.each_line { |line| puts "[ttyd-#{cid}] #{line.chomp}" }
          rescue => e
            puts "[ttyd-#{cid}] stdout error: #{e.message}"
          end
        end

        stderr_thread = Thread.new do
          begin
            stderr.each_line { |line| puts "[ttyd-#{cid}] ERROR: #{line.chomp}" }
          rescue => e
            puts "[ttyd-#{cid}] stderr error: #{e.message}"
          end
        end

        # Wait for process to complete
        wait_thr.join

        # Clean up output threads
        stdout_thread.kill rescue nil
        stderr_thread.kill rescue nil

        exit_code = wait_thr.value.exitstatus
        puts "ttyd process for #{cid} exited with code #{exit_code}"

        exit_code
      end
    rescue => e
      puts "Error running ttyd process for #{cid}: #{e.message}"
    ensure
      TTYD_SESSIONS.delete(cid)
    end
  end

  get '/ttyd/:cid/ws' do
    begin
      session = start_ttyd_session(params[:cid])

      return unless Async::WebSocket::Adapters::Rack.websocket?(env)

      protocols = env['HTTP_SEC_WEBSOCKET_PROTOCOL']&.split(',')&.map(&:strip) || []
      selected = protocols.include?('tty') ? ['tty'] : []

      Async::WebSocket::Adapters::Rack.open(env, protocols: selected) do |client|
        proxy_websocket_connection(client, session[:port])
      end
    rescue => e
      puts "WebSocket error for #{params[:cid]}: #{e.message}"
      halt 500, "Failed to establish WebSocket connection: #{e.message}"
    end
  end

  get '/ttyd/:cid*' do
    begin
      session = start_ttyd_session(params[:cid])
      path = params['splat'].first.to_s.split('/').last || ''

      proxy_http_request(session[:port], path)
    rescue => e
      puts "HTTP proxy error for #{params[:cid]}: #{e.message}"
      halt 500, "Internal server error: #{e.message}"
    end
  end

  private

  def proxy_websocket_connection(client, port)
    endpoint = Async::HTTP::Endpoint.parse("ws://localhost:#{port}/ws")

    # Wait a bit for ttyd to be ready
    3.times do
      begin
        Async::WebSocket::Client.connect(endpoint, protocols: ['tty']) do |ttyd_ws|
          puts "WebSocket connection established to ttyd on port #{port}"

          # Bidirectional message proxying
          tasks = [
            Async { proxy_messages(ttyd_ws, client, "ttyd->client") },
            Async { proxy_messages(client, ttyd_ws, "client->ttyd") }
          ]

          tasks.each(&:wait)
        end
        return # Success
      rescue => e
        puts "WebSocket connection attempt failed: #{e.message}"
        sleep 0.5
      end
    end

    raise "Failed to connect to ttyd WebSocket after 3 attempts"
  rescue => e
    puts "WebSocket proxy error: #{e.message}"
    raise
  ensure
    client.close rescue nil
  end

  def proxy_messages(from, to, direction = "")
    while message = from.read
      to.write(message)
      to.flush
    end
  rescue => e
    puts "Message proxy error (#{direction}): #{e.message}" unless direction.empty?
  ensure
    to.close rescue nil
  end

  def proxy_http_request(port, path)
    # Wait for ttyd HTTP server to be ready
    uri = URI("http://localhost:#{port}/#{path}")

    3.times do
      begin
        response = Net::HTTP.get_response(uri)

        content_type response['content-type'] if response['content-type']
        status response.code.to_i
        return response.body
      rescue Errno::ECONNREFUSED => e
        puts "Connection refused to ttyd on port #{port}, retrying..."
        sleep 0.5
      end
    end

    halt 503, "ttyd service unavailable on port #{port}"
  rescue => e
    puts "HTTP proxy request error: #{e.message}"
    halt 500, "Proxy request failed: #{e.message}"
  end
end