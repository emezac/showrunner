# frozen_string_literal: true

require "webrick"
require "json"
require "stringio"

module RubyA2A
  module Server
    # Lightweight WEBrick-based HTTP server wrapper.
    #
    # This is the zero-dependency runtime for standalone scripts.
    # For production, mount RubyA2A::Server::RackApp in Puma/Falcon instead.
    #
    # == Usage
    #
    #   server = RubyA2A::Server::HttpServer.new(
    #     executor: MyAgent.new,
    #     port:     8080
    #   )
    #   server.start
    #
    class HttpServer
      def initialize(executor:, port: 8080, host: "localhost", store: nil)
        @executor = executor
        @store    = store || TaskStore::InMemory.new
        @rack_app = RackApp.new(executor: executor, store: @store)

        @server = WEBrick::HTTPServer.new(
          Port:        port,
          BindAddress: host,
          AccessLog:   [],
          Logger:      WEBrick::Log.new($stderr, WEBrick::Log::WARN)
        )

        # Mount everything through the Rack app adapter
        @server.mount_proc("/") { |req, res| serve(req, res) }
      end

      def start
        @server.start
      end

      def shutdown
        @server.shutdown
      end

      private

      def serve(req, res)
        # Build a minimal Rack env from WEBrick request
        env = {
          "REQUEST_METHOD" => req.request_method,
          "PATH_INFO"      => req.path,
          "QUERY_STRING"   => req.query_string || "",
          "rack.input"     => StringIO.new(req.body || ""),
          "HTTP_AUTHORIZATION" => req["Authorization"].to_s,
          "HTTP_X_API_KEY"     => req["X-API-Key"].to_s,
          "CONTENT_TYPE"       => req["Content-Type"].to_s,
          "CONTENT_LENGTH"     => req["Content-Length"].to_s
        }

        status, headers, body = @rack_app.call(env)

        res.status = status
        headers.each { |k, v| res[k] = v }
        res.body = body.join
      end
    end
  end
end
