#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require 'sinatra/reloader'

get '*/stack*', &-> { slim :stack }
get '*/logs*', &-> { slim :logs }
get '*/inspect*', &-> { slim :inspect }
get '*/update*', &-> { slim :update }
get '*', &-> { slim :index }

run Sinatra::Application