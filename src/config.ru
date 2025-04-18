#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require 'sinatra/reloader'
require 'async/websocket/adapters/rack'
require 'open3'

get '*/stack*', &-> { slim :stack }

get '*/logs_ws*', &-> {
  if Async::WebSocket::Adapters::Rack.websocket?(env)
    Async::WebSocket::Adapters::Rack.open(env) do |connection|
      thread = Thread.new do
        Open3.popen3("docker service logs -n 10 -f #{params[:service]} 2>&1") do |_, stdout, _, _|
          while line = stdout.gets
            break if connection.closed?
            connection.write(line)
            connection.flush
          end
        end
      end

      while connection.read; end
    ensure
      thread&.kill
    end
  else
    slim :logs_ws
  end
}
get '*/logs*', &-> { slim :logs }
get '*/tag*', &-> { slim :tag }
get '*/journal*', &-> { slim :journal }
get '*/inspect*', &-> { slim :inspect }
get '*/ps*', &-> { slim :ps }
get '*/update*', &-> { slim :update }
get '*', &-> { slim :index }

run Sinatra::Application