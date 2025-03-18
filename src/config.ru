#!/usr/bin/env ruby

map '/' do
  run lambda { |env|
    [
      200,
      { 'content-type' => 'text/html' },
      ['<h1>Stack Insight</h1>' + "<pre> #{`docker ps`}</pre>"]
    ]
  }
end


