# frozen_string_literal: true

# Load the core ruby_a2a models so Server can use Models::Part, Models::Message, etc.
require_relative "../ruby_a2a" unless defined?(RubyA2A::AgentCard)

require_relative "server/task_store"
require_relative "server/executor"
require_relative "server/dispatcher"
require_relative "server/auth_middleware"
require_relative "server/rack_app"
require_relative "server/http_server"

module RubyA2A
  # The Server module provides all components needed to expose a Ruby object
  # as an A2A-compliant HTTP agent.
  #
  # == Quick Start (standalone script)
  #
  #   require "ruby_a2a/server"
  #
  #   class MyAgent < RubyA2A::Server::Executor
  #     agent_name        "MyAgent"
  #     agent_description "Does something useful"
  #     agent_url         "http://localhost:8080"
  #     capabilities      streaming: false
  #
  #     def handle_task(params, context)
  #       text = params.dig("message", "parts", 0, "text") || "Hello"
  #       context.update_status("working")
  #       context.complete!(build_agent_message(build_text_part("Echo: #{text}")))
  #     end
  #   end
  #
  #   server = RubyA2A::Server::HttpServer.new(executor: MyAgent.new, port: 8080)
  #   server.start
  #
  # == Rails / Rack Mount
  #
  #   # config/routes.rb
  #   require "ruby_a2a/server"
  #   mount RubyA2A::Server::RackApp.new(executor: MyAgent.new), at: "/a2a"
  #
  module Server
  end
end
