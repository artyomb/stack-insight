#!/usr/bin/env ruby
if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
  RubyVM::YJIT.enable
  puts "RubyVM::YJIT: #{RubyVM::YJIT.enabled?}"
else
  puts 'YJIT is not enabled'
end

require 'async'
require 'stack-service-base'
require 'stack-service-base/prometheus_parser'
require_relative 'insight_auth'

require_relative 'ttyd'
require_relative 'insight'

auth_options = InsightAuth.options
use InsightAuth, **auth_options if auth_options

StackServiceBase.rack_setup self

use Rack.middleware_klass do |env, app|
  env['PATH_INFO'].gsub!(/.*insight/, '')
  app.call env
end

METRICS_QUERY_RANGE = ENV['METRICS_QUERY_RANGE'] ||'http://victoriametrics:8428/api/v1/query_range'

run Rack::Cascade.new [ServerTtyd, ServerInsight]
