# frozen_string_literal: true

require_relative "strategy"

module RubyA2A
  module Auth
    # Adds an API key header to outgoing requests.
    # Credentials are NEVER placed in query parameters.
    class ApiKey < Strategy
      DEFAULT_HEADER = "X-API-Key"

      # @param key    [String] the API key value
      # @param header [String] the header name (default: "X-API-Key")
      def initialize(key, header: DEFAULT_HEADER)
        raise ArgumentError, "key must not be nil"     if key.nil?
        raise ArgumentError, "key must not be empty"   if key.to_s.strip.empty?
        raise ArgumentError, "header must not be nil"  if header.nil?
        raise ArgumentError, "header must not be empty" if header.to_s.strip.empty?

        @key    = key.to_s.freeze
        @header = header.to_s.freeze
      end

      # @param request [Net::HTTP::Request]
      # @return [Net::HTTP::Request]
      def apply!(request)
        raise ArgumentError, "request must not be nil" if request.nil?

        request[@header] = @key
        request
      end
    end
  end
end
