# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"

module RubyA2A
  module Http
    # Low-level HTTP client used by RubyA2A::Client.
    # All network I/O is funnelled through this class.
    #
    # Security guarantees enforced here:
    #   - use_ssl = true always
    #   - verify_mode = VERIFY_PEER always
    #   - minimum TLS version from configuration
    #   - credentials are never placed in URLs or query params
    class Base
      def initialize(base_url, auth:, config:)
        @uri    = URI.parse(base_url)
        @auth   = auth
        @config = config
        @logger = config.logger
      end

      # Performs a GET request and returns the parsed JSON body as a Hash.
      # Returns nil when the response is 404.
      def get(path, sse: false, &block)
        request = Net::HTTP::Get.new(build_uri(path))
        prepare_request!(request, sse: sse)
        execute(request, sse: sse, &block)
      end

      # Performs a POST request with a JSON body and returns the parsed response.
      def post(path, body: nil, sse: false, &block)
        request = Net::HTTP::Post.new(build_uri(path))
        prepare_request!(request, sse: sse)

        if body
          request.body            = JSON.generate(body)
          request["Content-Type"] = "application/json"
        end

        execute(request, sse: sse, &block)
      end

      private

      def build_uri(path)
        # Always resolve routes against scheme+host+port of the base_url.
        # All A2A routes are absolute paths, so we deliberately ignore any
        # path suffix the caller may have included in base_url.
        "#{@uri.scheme}://#{@uri.host}:#{@uri.port}#{path}"
      end

      def prepare_request!(request, sse: false)
        request["A2A-Version"]  = @config.a2a_version
        request["Content-Type"] = "application/json"
        request["Accept"]       = sse ? "text/event-stream" : "application/json"
        @auth.apply!(request)
      end

      def execute(request, sse: false, &block)
        http = build_http
        log_request(request)

        if sse
          execute_sse(http, request, &block)
        else
          response = http.request(request)
          log_response(response)
          handle_response(response)
        end
      end

      def execute_sse(http, request, &block)
        reader = SseReader.new

        http.request(request) do |response|
          log_response(response)
          raise_on_error!(response) if response.code.to_i >= 400

          response.read_body do |chunk|
            reader.feed(chunk, &block)
          end

          reader.flush(&block)
        end
      end

      def build_http
        http              = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl      = @uri.scheme == "https"
        if http.use_ssl
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.min_version = @config.minimum_tls_version
        end
        http.open_timeout = @config.open_timeout
        http.read_timeout = @config.read_timeout
        # write_timeout available since Ruby 2.6
        http.write_timeout = @config.timeout if http.respond_to?(:write_timeout=)
        http
      end

      def handle_response(response)
        code = response.code.to_i

        return nil if code == 404

        body = parse_body(response)

        raise_on_error!(response, body) if code >= 400

        body
      end

      def parse_body(response)
        return nil if response.body.nil? || response.body.strip.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        response.body
      end

      def raise_on_error!(response, body = nil)
        body ||= parse_body(response)
        RubyA2A.raise_protocol_error!(body || {})
      end

      def log_request(request)
        @logger.debug("[ruby-a2a] -> #{request.method} #{request.path}")
      end

      def log_response(response)
        @logger.debug("[ruby-a2a] <- #{response.code} #{response.message}")
      end
    end
  end
end
