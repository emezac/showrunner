# frozen_string_literal: true

module Agentkit
  # Registry for agent skills — reusable units of capability (tools, prompts,
  # context injectors) that agents can compose.
  #
  # Skills are plain Ruby modules that extend Agentkit::Skill::Base.
  # They are loaded from app/skills/ in the domain application and from
  # app/skills/agentkit/ in the engine itself.
  #
  # Usage:
  #   Agentkit::SkillRegistry.load_skill(:web_search)
  #   Agentkit::SkillRegistry.compose_skills(:rag, :web_search)
  #   Agentkit::SkillRegistry.available  # => [:web_search, :rag, ...]
  class SkillRegistry
    @registry = {}

    class << self
      # Register a skill module under a name.
      #   Agentkit::SkillRegistry.register(:rag, Agentkit::Skills::RagSkill)
      def register(name, mod)
        @registry[name.to_sym] = mod
        Rails.logger.debug("[AgentKit] Skill registered: #{name}") if defined?(Rails)
      end

      # Retrieve a skill module by name. Raises if not found.
      def load_skill(name)
        @registry.fetch(name.to_sym) do
          raise ArgumentError, "[AgentKit] Unknown skill: #{name}. " \
                               "Available: #{available.join(', ')}"
        end
      end

      # Return an array of skill modules.
      def compose_skills(*names)
        names.flatten.map { |n| load_skill(n) }
      end

      # List registered skill names.
      def available
        @registry.keys
      end

      # Auto-load all skill files from a path pattern (called during engine init).
      def autoload_from(path_pattern)
        Dir[path_pattern].each { |f| require f }
      end

      # Reset — used in tests.
      def reset!
        @registry = {}
      end
    end
  end

  # Base mixin for skill modules.
  # Include in your skill module and implement #system_prompt_fragment
  # and optionally #tools.
  #
  # Example:
  #   module MyDomain
  #     module Skills
  #       module LegalSkill
  #         extend Agentkit::Skill::Base
  #
  #         def self.system_prompt_fragment
  #           "You are an expert in Mexican corporate law. ..."
  #         end
  #
  #         def self.tools
  #           [:rag, :web_search]
  #         end
  #       end
  #     end
  #   end
  module Skill
    module Base
      def self.extended(mod)
        mod.instance_variable_set(:@tools, [])
      end

      def tools
        @tools ||= []
      end

      def system_prompt_fragment
        ""
      end
    end
  end
end
