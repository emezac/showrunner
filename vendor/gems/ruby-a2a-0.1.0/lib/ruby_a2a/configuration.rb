# frozen_string_literal: true

require "logger"

module RubyA2A
  class Configuration
    MINIMUM_TLS_VERSIONS = {
      "TLS1_2" => OpenSSL::SSL::TLS1_2_VERSION,
      "TLS1_3" => OpenSSL::SSL::TLS1_3_VERSION
    }.freeze

    attr_accessor :timeout,
                  :open_timeout,
                  :read_timeout,
                  :poll_interval,
                  :max_poll_attempts,
                  :a2a_version,
                  :logger,
                  :minimum_tls_version

    def initialize
      @timeout             = 30
      @open_timeout        = 10
      @read_timeout        = 30
      @poll_interval       = 1.0
      @max_poll_attempts   = 60
      @a2a_version         = "1.0"
      @logger              = ::Logger.new($stdout, level: ::Logger::WARN)
      @minimum_tls_version = OpenSSL::SSL::TLS1_2_VERSION
    end
  end
end
