# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "yaml"

class SidekiqConfigurationTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").expand_path

  def test_development_worker_consumes_every_application_queue
    config_path = ROOT.join("config", "sidekiq.yml")
    config = YAML.safe_load_file(config_path, permitted_classes: [Symbol], aliases: true)
    queues = Array(config[:queues] || config[":queues"] || config["queues"]).map do |entry|
      Array(entry).first.to_s
    end

    assert_includes queues, "agentkit_agents"
    assert_includes queues, "default"
    assert_includes queues, "agentkit_embeddings"
    assert_includes queues, "agentkit_hitl"

    worker_command = ROOT.join("Procfile.dev").read.lines.find { |line| line.start_with?("worker:") }
    assert_includes worker_command, "-C config/sidekiq.yml"
  end
end
