# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/mock'
require 'tmpdir'
require 'json'
require_relative '../insight'

class TagTest < Minitest::Test
  class App < ServerInsight
    set :views, File.expand_path('../views', __dir__)
    helpers { def docker(_api) = { 'Name' => 'test-node' } }
  end

  REPO = 'registry.example:5000/team/app'
  DIGEST = "sha256:#{'a' * 64}"
  OTHER = "sha256:#{'b' * 64}"

  def setup
    @dir = Dir.mktmpdir('insight-tag')
    @original_path = ENV.fetch('PATH')
    File.write("#{@dir}/docker", <<~'SH')
      #!/bin/sh
      cd "$(dirname "$0")" || exit 1
      case "$1" in
        ps) echo 'container-1 container-2' ;;
        inspect) cat containers ;;
        stack) cat tasks ;;
        image) cat "$3.json" || { echo '[]'; exit 1; } ;;
        pull|tag|push) echo "$*" >> calls; test ! -f "fail-$1" ;;
        *) exit 1 ;;
      esac
    SH
    File.chmod(0o755, "#{@dir}/docker")
    ENV['PATH'] = "#{@dir}:#{@original_path}"
    tasks = %w[healthy missing].map { |name| { 'Name' => name, 'ID' => name, 'Image' => "#{REPO}:latest@#{DIGEST}" } }
    containers = tasks.map { |t| { 'Image' => t['Name'], 'Config' => { 'Labels' => { 'com.docker.swarm.task.id' => t['ID'] } } } }
    File.write("#{@dir}/containers", containers.to_json)
    File.write("#{@dir}/tasks", tasks.map(&:to_json).join("\n"))
    image = { 'RepoDigests' => ["other.example/app@#{DIGEST}", "#{REPO}@#{OTHER}", "#{REPO}@#{DIGEST}"] }
    File.write("#{@dir}/healthy.json", [image].to_json)
    File.write("#{@dir}/calls", '')
    @request = Rack::MockRequest.new(App)
  end

  def teardown
    ENV['PATH'] = @original_path
    FileUtils.remove_entry(@dir)
  end

  def publish(*services)
    @request.post('/tag?stack=test', params: { 'services' => services, 'tag' => 'release' })
  end

  def test_get_keeps_both_rows_and_post_only_publishes_the_matching_digest
    page = @request.get('/tag?stack=test')
    assert_equal 200, page.status
    assert_includes page.body, '>missing</td>'
    assert_includes page.body, 'Local image unavailable'
    assert_includes page.body, 'value="healthy"'
    refute_includes page.body, 'value="missing"'

    response = publish('missing', 'healthy')
    assert_equal 200, response.status
    assert_includes response.body, 'Skipped missing: Local image unavailable'
    source = "#{REPO}@#{DIGEST}"
    assert_equal ["pull #{source}", "tag #{source} #{REPO}:release", "push #{REPO}:release"], File.readlines("#{@dir}/calls", chomp: true)
  end

  def test_post_rechecks_local_image_and_rejects_unrelated_digests
    assert_includes @request.get('/tag?stack=test').body, 'value="healthy"'
    File.unlink("#{@dir}/healthy.json")
    File.write("#{@dir}/missing.json", [{ 'RepoDigests' => ["other.example/app@#{DIGEST}", "#{REPO}@#{OTHER}"] }].to_json)

    response = publish('healthy', 'missing')
    assert_includes response.body, 'Skipped healthy: Local image unavailable'
    assert_includes response.body, 'Skipped missing: No matching repository digest'
    assert_empty File.read("#{@dir}/calls")
  end

  def test_failed_tag_stops_publication
    File.write("#{@dir}/fail-tag", '')
    response = publish('healthy')
    assert_includes response.body, 'class="error"'
    assert_equal %w[pull tag], File.readlines("#{@dir}/calls").map { |line| line.split.first }
  end

  def test_unpinned_service_uses_a_digest_from_its_own_repository
    File.write("#{@dir}/tasks", { 'Name' => 'healthy', 'ID' => 'healthy', 'Image' => "#{REPO}:latest" }.to_json)
    publish('healthy')
    assert_equal "pull #{REPO}@#{OTHER}", File.readlines("#{@dir}/calls", chomp: true).first
  end
end
