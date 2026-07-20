# frozen_string_literal: true

require_relative "strategy"

module RubyA2A
  module Auth
    # Optional OAuth2 authentication strategy.
    # Requires the `oauth2` gem (not a runtime dependency of ruby-a2a).
    # If `oauth2` is unavailable, raises a descriptive LoadError at instantiation.
    #
    # Usage (requires `gem "oauth2"` in the caller's Gemfile):
    #   token  = OAuth2::AccessToken.new(client, "my-access-token")
    #   strategy = RubyA2A::Auth::OAuth2.new(token)
    class OAuth2 < Strategy
      # @param access_token [#token] an object that responds to #token and returns
      #   a String bearer token. Typically an OAuth2::AccessToken instance.
      def initialize(access_token)
        ensure_oauth2_available!

        raise ArgumentError, "access_token must not be nil" if access_token.nil?
        unless access_token.respond_to?(:token)
          raise ArgumentError, "access_token must respond to #token"
        end

        @access_token = access_token
      end

      # @param request [Net::HTTP::Request]
      # @return [Net::HTTP::Request]
      def apply!(request)
        raise ArgumentError, "request must not be nil" if request.nil?

        token = @access_token.token
        raise ArgumentError, "access_token#token returned nil" if token.nil?

        request["Authorization"] = "Bearer #{token}"
        request
      end

      private

      def ensure_oauth2_available!
        require "oauth2"
      rescue LoadError
        raise LoadError,
          "The `oauth2` gem is required for RubyA2A::Auth::OAuth2. " \
          "Add `gem 'oauth2', '~> 2.0'` to your Gemfile."
      end
    end
  end
end
