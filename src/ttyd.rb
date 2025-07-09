require 'sinatra/base'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'uri'
require 'open3'

$cid2thread = {}

class ServerTtyd < Sinatra::Base
  helpers do
    def new_port
      port = 8000
      while port <= 8010
        return port unless $cid2thread.values.any? { |info| info[:port] == port }
        port += 1
      end
      raise 'No available ports in range 8000-9000'
    end

    otl_def def start_ttyd(cid)

      $cid2thread.delete_if do |cid, info|
        !system("ps ax | grep ttyd | grep #{info[:port]}")
      end

      ttyd = $cid2thread[cid]
      return ttyd unless ttyd.nil? || ttyd[:thread].nil?

      thrd = Thread.new do
        path = 'sh'
        path = 'bash' if system("docker exec #{cid} ls /bin/bash")

        port = new_port
        logs = []
        otl_span "ttyd cid: #{cid}, port: #{port}, path: #{path}", { cid: , port:, path: } do
          $cid2thread[cid] = { thread: thrd, cid:, port:, logs: }
          Open3.popen3("ttyd -p #{port} -W docker exec -it #{cid} #{path}") do |stdin, stdout, stderr, wait_thr|
            # Open3.popen3("ttyd -p #{port} -W ssh swarm") do |stdin, stdout, stderr, wait_thr|
            $cid2thread[cid][:wait_thr] = wait_thr
            stdin.close
            while line = stdout.gets; logs << line end
            while line = stderr.gets; logs << line end
            wait_thr.join
            return_value = wait_thr.value

            $cid2thread[cid][:exit_code] = return_value.exitstatus
          end
          puts "ttyd process for container #{cid} exited with code #{$cid2thread[cid][:exit_code]}"
        end
      ensure
        if $cid2thread[:cid]
          Process.kill("KILL",$cid2thread[:cid][:wait_thr].pid)
          $cid2thread[:cid][:tread] = nil
          $cid2thread[:cid][:wait_thr] = nil
          $cid2thread.delete(cid)
        end
      end

      sleep 1
      if $cid2thread[cid][:thread].nil?
        $cid2thread.delete(cid)
        raise "ttyd process for container #{cid} failed to start"
      end
      $cid2thread[cid]
    end
  end

  get '/ttyd/:cid/ws' do
    ttyd = start_ttyd params[:cid]

    if Async::WebSocket::Adapters::Rack.websocket?(env)
      protocols = env['HTTP_SEC_WEBSOCKET_PROTOCOL']&.split(',')&.map(&:strip) || []
      selected_protocol = protocols.include?('tty') ? 'tty' : nil

      Async::WebSocket::Adapters::Rack.open(env, protocols: selected_protocol ? [selected_protocol] : []) do |client|
        endpoint = Async::HTTP::Endpoint.parse("ws://localhost:#{ttyd[:port]}/ws")

        Async::WebSocket::Client.connect(endpoint, protocols: ['tty']) do |ttyd_con|

          ttyd_to_client = Async do
            while message = ttyd_con.read
              client.write(message)
              client.flush
            end
          ensure
            client.close rescue nil
          end

          client_to_ttyd = Async do
            while message = client.read
              ttyd_con.write(message)
              ttyd_con.flush
            end
          ensure
            ttyd_con.close rescue nil
          end

          ttyd_to_client.wait
          client_to_ttyd.wait
        rescue => e
          puts "ws client error: #{e.message}"
        ensure
          Process.kill("KILL",ttyd[:wait_thr].pid)
          # ttyd[:thread]&.exit rescue nil
          ttyd[:thread] = nil
          $cid2thread.delete(params[:cid])
        end

      rescue => e
        puts "ws adapter error: #{e.message}"
        client.close rescue nil
      end
    end
  rescue =>e
    puts "get ws error: #{e.message}"
  end

  get '/ttyd/:cid*' do
    ttyd = start_ttyd params[:cid]

    path = params['splat'].first.split('/').last
    uri = URI("http://localhost:#{ttyd[:port]}/#{path}")
    response = Net::HTTP.get_response(uri)

    content_type response['content-type'] if response['content-type']
    status response.code.to_i
    response.body
  end
end