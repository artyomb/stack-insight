require 'sinatra/base'
require 'async/websocket/adapters/rack'
require 'async/websocket/client'
require 'async/http/endpoint'
require 'net/http'
require 'uri'
require 'open3'
require 'json'
require 'shellwords'

class ServerInsight < Sinatra::Base
  before do
    @calc_size = ENV['CONTAINER_SIZE'] == 'false' ? '--size=false' : ''
    @calc_size_inspect = ENV['CONTAINER_SIZE'] == 'false' ? '' : '-s'
    @dinfo = docker('info')
  end

  helpers do()
    def inspect_tag_image(id)
      stdout, _, status = Open3.capture3('docker', 'image', 'inspect', id)
      JSON.parse(stdout).first if status.success?
    end

    def tag_image_row(task, container, images)
      reference = task.fetch('Image')
      name, pinned_digest = reference.split('@', 2)
      row = { Name: task['Name'], Image: reference }
      return row unless name.match?(%r{\A[^/]+\.[^/]+/})

      repository = row[:Repository] = name.sub(%r{:[^/:]+\z}, '')
      id = container&.[]('Image')
      image = images.fetch(id) { images[id] = inspect_tag_image(id) } if id
      unless image
        row[:Unavailable] = 'Local image unavailable'
        return row
      end

      row[:Digests] = Array(image['RepoDigests']).filter_map do |entry|
        repo, digest = entry.split('@', 2)
        next unless repo == repository && /\Asha256:[0-9a-f]{64}\z/.match?(digest)
        digest if pinned_digest.nil? || digest == pinned_digest
      end
      row[:Unavailable] = 'No matching repository digest' if row[:Digests].empty?
      row[:Tags] = Array(image['RepoTags']).filter_map do |entry|
        repo, _, tag = entry.rpartition(':')
        tag if repo == repository
      end
      row[:Version] = image.dig('Config', 'Labels', 'org.opencontainers.image.version')
      row[:Created] = image['Created']
      row
    end

    def publish_image_tag(row, target_tag)
      if row[:Unavailable]
        return { error: true, output: "Skipped #{row[:Name]}: #{row[:Unavailable]}" }
      end

      source = "#{row[:Repository]}@#{row[:Digests].first}"
      target = "#{row[:Repository]}:#{target_tag}"
      output = +""
      [['pull', source], ['tag', source, target], ['push', target]].each do |args|
        output << "# docker #{args.shelljoin}\n"
        message, status = Open3.capture2e('docker', *args)
        output << message
        return { error: true, output: output } unless status.success?
      end
      { output: output }
    end

    def favicon(dinfo)
      name = dinfo['Name'].split(/\.|_|-/).map { |s| s.capitalize.chars.first }.slice(0..1).join
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
          <rect width="32" height="32" fill="#4A4A4A"/>
          <text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" fill="white" font-family="Arial" font-size="20">#{name}</text>
        </svg>
      SVG
    end

    # https://docs.docker.com/reference/api/engine/version/v1.44/
    # https://docs.docker.com/reference/api/engine/version-history/
    def docker(api, json=true)
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

          raise response unless $?.success?
          json ? JSON(response, symbolize_key: true) : response
        rescue => e
          raise "Exception: #{response}"
        end
      end
    end

    def tempo_search(container_id, query)
      command = [
        'docker', 'exec', container_id, 'curl',
        '--silent', '--show-error', '--fail', '--get',
        '--connect-timeout', ENV.fetch('TEMPO_CONNECT_TIMEOUT', '2'),
        '--max-time', ENV.fetch('TEMPO_SEARCH_TIMEOUT', '5')
      ]
      query.each { |key, value| command.concat ['--data-urlencode', "#{key}=#{value}"] }
      command << 'http://tempo:3200/api/search'

      stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        detail = stderr.strip
        detail = stdout.strip if detail.empty?
        raise "request exited with status #{status.exitstatus}: #{detail.slice(0, 200)}"
      end

      JSON(stdout, symbolize_names: true)
    rescue StandardError => e
      @tempo_search_error = 'Tempo search is unavailable; exception data was omitted.'
      LOGGER.warn "Tempo search failed (#{e.class}): #{e.message}"
      {}
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
  get '/restart*', &-> { slim :restart }
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
