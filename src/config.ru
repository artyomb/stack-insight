#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require 'sinatra/reloader'
# set :inline_templates, true

get '*/stack*', &-> { slim :stack }
get '*/logs*', &-> { slim :logs }
get '*/inspect*', &-> { slim :inspect }
get '*', &-> { slim :index }

run Sinatra::Application

__END__
@@layout
  sass:
    body1
      background-color: black
      color: white
    .action
      margin-left: 1em
  javascript:
      if (!location.href.includes('?') && !location.href.endsWith('/')) { location.href = location.href + '/'; }
  == yield

@@index
  h1 Stack Insight: #{params[:stack]}
  pre: ul
    - stack_ls = `docker stack ls --format '{{json .}}'`.lines.map { JSON.parse _1 }
    - stack_ls.each do |s|
      li : a href="stack?stack=#{s['Name']}" #{s['Name']}  (#{s['Services']})
  pre = `docker ps`

@@stack
  h1 Stack: #{params[:stack]}
  pre: ul
    - services = `docker service ls --filter label=com.docker.stack.namespace=#{params[:stack]} --format '{{json .}}'`.lines.map { JSON.parse _1 }
    - services.each do |s|
      li
        span #{s['Name']} (#{s['Mode']} #{s['Replicas']})
        a.action href="inspect/?stack=#{params[:stack]}&service=#{s['ID']}" inspect
        a.action href="logs/?stack=#{params[:stack]}&service=#{s['ID']}" logs
        a.action href="update/?stack=#{params[:stack]}&service=#{s['ID']}" update

@@logs
  h1 Logs: #{params[:service]}
  // --raw
  pre = `docker service logs -n 100 --raw -t #{params[:service]}`

@@inspect
  h1 Inspect: #{params[:service]}
  pre = `docker service inspect #{params[:service]}`
