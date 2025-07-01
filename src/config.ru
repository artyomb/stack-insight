#!/usr/bin/env ruby
require 'async'
require 'stack-service-base'
require 'stack-service-base/prometheus_parser'

require_relative 'ttyd'
require_relative 'insight'

StackServiceBase.rack_setup self

use Rack.middleware_klass do |env, app|
  env['PATH_INFO'].gsub!(/.*insight/, '')
  app.call env
end

run Rack::Cascade.new [ServerTtyd, ServerInsight]