#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require 'sinatra/reloader'
# set :inline_templates, true

get '*/stack*', &-> { slim :stack }
get '*/logs*', &-> { slim :logs }
get '*/inspect*', &-> { slim :inspect }
get '*/update*', &-> { slim :update }
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
    - stack_ls = `docker stack ls --format '{{json .}}' 2>&1`.lines.map { JSON.parse _1 }
    - stack_ls.each do |s|
      li : a href="stack?stack=#{s['Name']}" #{s['Name']}  (#{s['Services']})
  pre = `docker ps 2>&1`

@@stack
  h1 Stack: #{params[:stack]}
  pre: ul
    - services = `docker service ls --filter label=com.docker.stack.namespace=#{params[:stack]} --format '{{json .}}' 2>&1`.lines.map { JSON.parse _1 }
    - services.each do |s|
      li
        span #{s['Name']} (#{s['Mode']} #{s['Replicas']})
        a.action href="inspect/?stack=#{params[:stack]}&service=#{s['Name']}" inspect
        a.action href="logs/?stack=#{params[:stack]}&service=#{s['Name']}" logs
        a.action href="update/?stack=#{params[:stack]}&service=#{s['Name']}" update

@@logs
  h1 Service Logs: #{params[:service]}
  / - logs = `docker service logs -n 100 --raw -t #{params[:service]}`
  - logs = `docker service logs #{params[:service]} 2>&1`
  pre == logs

@@inspect
  h1 Service Inspect: #{params[:service]}
  h2 Docker ps
  pre = `docker ps --no-trunc 2>&1 | grep #{params[:service]}`.gsub /\s+/, ' '
  h2 Docker service ps
  pre = `docker service ps --no-trunc #{params[:service]} 2>&1`
  h2 Docker service inspect
  pre = `docker service inspect #{params[:service]} 2>&1`

@@update
  h1 Update Service: #{params[:service]}
  / h2 Docker pull image
  / pre = `docker service update --detach --force #{params[:service]} 2>&1 | grep -vE '\[.*=>.*\]'`
  h2 Docker service update
  pre = `docker service update --force #{params[:service]} 2>&1 | grep -vE '\[.*=>.*\]'`

