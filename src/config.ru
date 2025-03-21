#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require 'sinatra/reloader'
# set :inline_templates, true

get '/', &-> { slim :index }

run Sinatra::Application

__END__

@@index
  h1 Stack Insight: #{params[:stack]}
  sass:
    .action
      margin-left: 1em
  pre
    - unless params[:stack]
      ul
        - stack_ls = `docker stack ls --format '{{json .}}'`.lines.map { JSON.parse _1 }
        - stack_ls.each do |s|
          li : a href="/?stack=#{s['Name']}" #{s['Name']}  (#{s['Services']})
      pre = `docker service ls`
    - else
      - services = `docker service ls --filter label=com.docker.stack.namespace=#{params[:stack]} --format '{{json .}}'`.lines.map { JSON.parse _1 }
      ul
        - services.each do |s|
          // extract all service parameters
          li
            span #{s['Name']} (#{s['Mode']} #{s['Replicas']})
            a.action href="inspect/?stack=#{params[:stack]}&service=#{s['ID']}" inspect
            a.action href="logs/?stack=#{params[:stack]}&service=#{s['ID']}" logs
            a.action href="update/?stack=#{params[:stack]}&service=#{s['ID']}" update

