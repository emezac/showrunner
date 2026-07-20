# frozen_string_literal: true

require "json"

module RubyA2A
  module Server
    # Rack-compatible authentication middleware.
    #
    # Validates incoming requests before they reach the Dispatcher.
    # Only protects the JSON-RPC endpoint — the agent card is always public.
    #
    # == Usage
    #
    #   app = RubyA2A::Server::RackApp.new(executor: MyAgent.new, store: store)
    #
    #   # Wrap with auth middleware:
    #   protected_app = RubyA2A::Server::AuthMiddleware.new(
    #     app,
    #     validator: ->(token) { token == ENV["AGENT_TOKEN"] }
    #   )
    #
    class AuthMiddleware
      AGENT_CARD_PATH  = "/.well-known/agent.json"
      AGENT_CARD_PATH2 = "/.well-known/agent-card.json"

      # @param app       [#call]   The next Rack application
      # @param validator [#call]   Lambda/proc receiving the extracted token.
      #                            Return true to allow, false to deny.
      # @param scheme    [Symbol]  :bearer_token (default) or :api_key
      def initialize(app, validator:, scheme: :bearer_token)
        @app       = app
        @validator = validator
        @scheme    = scheme
      end

      def call(env)
        # Agent card discovery is always public
        if public_path?(env["PATH_INFO"])
          return @app.call(env)
        end

        token = extract_token(env)

        if token && @validator.call(token)
          @app.call(env)
        else
          unauthorized_response
        end
      end

      private

      def public_path?(path)
        path == AGENT_CARD_PATH || path == AGENT_CARD_PATH2
      end

      def extract_token(env)
        case @scheme
        when :bearer_token
          auth_header = env["HTTP_AUTHORIZATION"] || ""
          match = auth_header.match(/\ABearer\s+(.+)\z/i)
          match&.captures&.first
        when :api_key
          env["HTTP_X_API_KEY"]
        end
      end

      def unauthorized_response
        body = JSON.generate({
          "jsonrpc" => "2.0",
          "id"      => nil,
          "error"   => {
            "code"    => -32_600,
            "message" => "Unauthorized: valid authentication credentials are required"
          }
        })

        [
          401,
          { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s },
          [body]
        ]
      end
    end
  end
end
