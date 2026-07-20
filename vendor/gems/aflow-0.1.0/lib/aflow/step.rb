# frozen_string_literal: true

module Aflow
  # Abstract base class. Subclass and override #id and #call.
  #
  #   class MyStep < Aflow::Step
  #     def id = "my_step"
  #
  #     def call(context)
  #       # ... do work ...
  #       Aflow::StepResult.success(output: { result: 42 })
  #     end
  #   end
  #
  # Optional retry/timeout/fallback configuration via .config:
  #
  #   class MyStep < Aflow::Step
  #     config retry: 3, timeout: 5, on_error: :continue
  #   end
  class Step
    # Per-class configuration DSL
    def self.config(options = nil)
      if options
        @config = default_config.merge(options)
      else
        @config || default_config
      end
    end

    def self.default_config
      {
        retry:    0,
        timeout:  nil,      # seconds, nil = no timeout
        fallback: nil,      # step id to delegate to on error
        on_error: :halt     # :halt | :continue
      }
    end

    # Subclasses MUST override this.
    def id
      raise NotImplementedError, "#{self.class}#id is not implemented"
    end

    # Subclasses MUST override this.
    # Must return an Aflow::StepResult.
    def call(context)
      raise NotImplementedError, "#{self.class}#call is not implemented"
    end

    # Resolved config for this instance (delegates to class-level config).
    def config
      self.class.config
    end

    def inspect
      "#<#{self.class.name} id=#{id.inspect}>"
    end
  end
end
