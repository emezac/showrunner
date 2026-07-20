# frozen_string_literal: true

module RubyA2A
  module Server
    # Pluggable task persistence layer.
    #
    # The InMemory backend is the default. Implement the same interface
    # to plug in Redis, ActiveRecord, etc.
    #
    # Required interface:
    #   save_task(task_hash)           → task_hash
    #   get_task(id)                   → task_hash | nil
    #   update_task_status(id, status) → task_hash | nil
    #   all_tasks                      → Array<task_hash>
    module TaskStore
      # Thread-safe, in-process task store backed by a plain Hash.
      class InMemory
        VALID_STATES = %w[
          submitted
          working
          input-required
          completed
          canceled
          failed
          unknown
        ].freeze

        def initialize
          @store = {}
          @mutex = Mutex.new
        end

        # Persists a new or updated task hash.
        # Raises ArgumentError if the task has no id.
        #
        # @param task [Hash] A2A task hash (string keys, camelCase)
        # @return [Hash]
        def save_task(task)
          raise ArgumentError, "task must be a Hash"         unless task.is_a?(Hash)
          raise ArgumentError, "task must have an 'id'"     unless task["id"]

          @mutex.synchronize { @store[task["id"]] = task.dup.freeze }
        end

        # @param id [String]
        # @return [Hash, nil]
        def get_task(id)
          @mutex.synchronize { @store[id]&.dup }
        end

        # Updates the status sub-object of an existing task.
        # Merges *state* and *message* into the existing status hash.
        #
        # @param id     [String]
        # @param status [Hash]   e.g. { "state" => "working", "message" => { ... } }
        # @return [Hash, nil] updated task or nil if not found
        def update_task_status(id, status)
          @mutex.synchronize do
            task = @store[id]
            return nil unless task

            updated = task.merge("status" => (task["status"] || {}).merge(status)).freeze
            @store[id] = updated
            updated.dup
          end
        end

        # @return [Array<Hash>]
        def all_tasks
          @mutex.synchronize { @store.values.map(&:dup) }
        end

        # @param id [String]
        # @return [Boolean]
        def delete_task(id)
          @mutex.synchronize { !@store.delete(id).nil? }
        end
      end
    end
  end
end
