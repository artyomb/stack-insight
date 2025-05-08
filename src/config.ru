#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require 'sinatra/reloader'
require 'async/websocket/adapters/rack'
require 'open3'

require 'stack-service-base'
require 'stack-service-base/prometheus_parser'

StackServiceBase.rack_setup self

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
get '/favicon.ico' do
  dinfo = JSON `docker info --format "{{json .}}"`
  name = dinfo['Name'].split( '.' ).map { |s| s.capitalize.chars.first }.slice(0..1).join
  content_type 'image/svg+xml'
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
      <rect width="32" height="32" fill="#4A4A4A"/>
      <text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" fill="white" font-family="Arial" font-size="16">#{name}</text>
    </svg>
  SVG
end
get '*/tempo*', &-> { slim :tempo }
get '*/logs*', &-> { slim :logs }
get '*/tag*', &-> { slim :tag }
get '*/journal*', &-> { slim :journal }
get '*/inspect*', &-> { slim :inspect }
get '*/ps*', &-> { slim :ps }
get '*/update*', &-> { slim :update }
get '*', &-> { slim :index }
post '*/tag*', &-> { slim :tag }

run Sinatra::Application