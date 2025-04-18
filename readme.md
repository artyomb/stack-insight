# stack-insight
dry-stack.drs
```ruby
Service :stack_insight, image: 'dtorry/stack-insight', ports: 7000 do
  volume '/var/run/docker.sock:/var/run/docker.sock'
  volume '/root/.docker/config.json:/root/.docker/config.json'
  volume '/var/log/journal:/var/log/journal:ro'
  volume '/run/systemd/journal:/run/systemd/journal:ro'
end
```