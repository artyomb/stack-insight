require 'sinatra/base'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'uri'
require 'open3'

class ServerInsight < Sinatra::Base
  before do
    @calc_size = ENV['CONTAINER_SIZE'] == 'false' ? '--size=false' : ''
    @calc_size_inspect = ENV['CONTAINER_SIZE'] == 'false' ? '' : '-s'
    @dinfo = docker('info')
  end

  helpers do()
    def favicon(dinfo)
      name = dinfo['Name'].split(/\.|_|-/).map { |s| s.capitalize.chars.first }.slice(0..1).join
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
          <rect width="32" height="32" fill="#4A4A4A"/>
          <text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" fill="white" font-family="Arial" font-size="20">#{name}</text>
        </svg>
      SVG
    end

    def docker(api)
      Async do
        otl_span(api) do
          path, params_str = api.split('?')
          params = params_str.to_s.split('&')
          cmd = [
            "curl -s -G --unix-socket /var/run/docker.sock",
            *params.map { |p| "--data-urlencode '#{p}'" },
            "http://localhost/#{path}"
          ].join(' ')

          response = ENV['RACK_ENV'] == 'production' ?
                       `#{cmd} 2>&1` :
                       `docker run --rm --privileged --pid=host alpine:edge nsenter -t 1 -m -u -n -i #{cmd} 2>&1`

          JSON(response, symbolize_key: true)
        rescue => e
          raise "Exception: #{response}"
        end
      end
    end
  end

  get '/stack2*', &-> { slim :stack }
  get '/stack*', &-> { slim :stack_main }

  get '/logs_ws*', &-> {
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
    content_type 'image/svg+xml'
    favicon(@dinfo.wait)
  end
  get '/partial_stack*', &-> { slim :stack2, layout: false }
  get '/partial_tempo*', &-> { slim :tempo, layout: false }
  get '/partial_metrics*', &-> { slim :metrics, layout: false }
  get '/partial_nats*', &-> { slim :nats, layout: false }
  get '/partial_rate_limits*', &-> { slim :rate_limits, layout: false }
  get '/logs*', &-> { slim :logs }
  get '/tag*', &-> { slim :tag }
  get '/journal*', &-> { slim :journal }
  get '/inspect*', &-> { slim :inspect }
  get '/ps*', &-> { slim :ps }
  get '/update*', &-> { slim :update }
  get '/', &-> { slim :index }
  post '/tag*', &-> { slim :tag }

  set :show_exceptions, false
  error do
    $stderr.puts "Error: #{env['sinatra.error']}"
    $stderr.puts env['sinatra.error'].backtrace.join("\n")

    status 500
    <<~HTML
      <h2>#{env['sinatra.error']}</h2>
      <pre>#{env['sinatra.error'].backtrace.join "\n"}</pre>
    HTML
  end

end
