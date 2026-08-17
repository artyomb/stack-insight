# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/mock'
require_relative '../ttyd'

class ServerTtydTest < Minitest::Test
  class App < ServerTtyd
    helpers do
      def start_session(_cid) = { port: 8000 }
    end
  end

  def test_non_websocket_request_does_not_fail_during_cleanup
    response = Rack::MockRequest.new(App).get('/ttyd/container/ws')

    refute_equal 500, response.status
  end
end
