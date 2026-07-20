# frozen_string_literal: true

require_relative "strategy"

module RubyA2A
  module Auth
    # Adds an Authorization: Bearer <token> header to outgoing requests.
    # The token is supplied externally; this gem never issues tokens.
    class BearerToken < Strategy
      # @param token [String] the bearer token
      def initialize(token)
        raise ArgumentError, "token must not be nil"   if token.nil?
        raise ArgumentError, "token must not be empty" if token.to_s.strip.empty?

        @token = token.to_s.freeze
      end

      # @param request [Net::HTTP::Request]
      # @return [Net::HTTP::Request]
      def apply!(request)
        raise ArgumentError, "request must not be nil" if request.nil?

        request["Authorization"] = "Bearer #{@token}"
        request
      end
    end
  end
end
