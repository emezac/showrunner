# frozen_string_literal: true

module Agentkit
  # Concern that enables ActiveRecord models to trigger agents automatically
  # on lifecycle events (after_create, after_update, etc.).
  #
  # Include in any domain model and use `trigger_agent` DSL to declare
  # which agents run on which events.
  #
  # Usage:
  #   class Caso < ApplicationRecord
  #     include Agentkit::AgentTriggerable
  #
  #     trigger_agent CasoIntakeAgent, on: :create
  #     trigger_agent CasoRiskAgent,   on: :create, async: true
  #     trigger_agent ScopeGuardAgent, on: :update, if: :brief_changed?
  #   end
  #
  # Options:
  #   on:    [:create, :update, :destroy]   — AR callback event (required)
  #   async: true | false                   — run via Sidekiq (default: true)
  #   if:    Symbol | Proc                  — conditional guard (optional)
  module AgentTriggerable
    extend ActiveSupport::Concern

    included do
      # Registry of trigger declarations for this model class.
      # Stored as class-level array of hashes.
      class_attribute :_agent_triggers, default: []
    end

    class_methods do
      # Declare an agent trigger.
      #
      # @param agent_class [Class]  The agent class to instantiate and call.
      # @param on          [Symbol] The AR callback (:create, :update, :destroy).
      # @param async       [Boolean] Run via AgentWorkerJob (default: true).
      # @param if          [Symbol, Proc, nil] Guard condition.
      def trigger_agent(agent_class, on:, async: true, if: nil)
        guard = binding.local_variable_get(:if)

        self._agent_triggers = _agent_triggers + [
          { agent: agent_class, event: on.to_sym, async: async, guard: guard }
        ]

        # Register the AR callback
        callback_name = :"after_#{on}"

        send(callback_name) do
          trigger = self.class._agent_triggers.select { |t| t[:event] == on.to_sym }
          trigger.each do |t|
            next unless passes_guard?(t[:guard])

            if t[:async]
              Agentkit::AgentWorkerJob.perform_later(
                t[:agent].name,
                self.class.name,
                self.id,
                current_triggering_user_id
              )
            else
              t[:agent].new(user: triggering_user).call(self)
            end
          end
        end
      end
    end

    # ─── Instance helpers ─────────────────────────────────────────────────────

    # Override in domain model if you want to pass a specific user to the agent.
    # Default: tries `user` association, then nil.
    def triggering_user
      respond_to?(:user) ? user : nil
    end

    def current_triggering_user_id
      triggering_user&.id
    end

    private

    def passes_guard?(guard)
      return true if guard.nil?
      return send(guard) if guard.is_a?(Symbol)
      return instance_exec(&guard) if guard.is_a?(Proc)

      true
    end
  end
end
