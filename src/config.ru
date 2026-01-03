#!/usr/bin/env ruby
puts "RubyVM::YJIT: #{RubyVM::YJIT.enabled?}"
if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
  RubyVM::YJIT.enable
else
  puts 'YJIT is not enabled'
end
puts "RubyVM::YJIT: #{RubyVM::YJIT.enabled?}"

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
