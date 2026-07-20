# frozen_string_literal: true

require "securerandom"

module RubyA2A
  module Server
    # Base class that agent authors inherit from.
    #
    # == DSL Example
    #
    #   class MyAgent < RubyA2A::Server::Executor
    #     agent_name        "MyAgent"
    #     agent_description "Does amazing things"
    #     agent_url         "https://myagent.example.com"
    #     protocol_version  "0.2.1"
    #
    #     capabilities streaming: true, push_notifications: false
    #
    #     skill id:          "summarize",
    #           name:        "Summarize Text",
    #           description: "Returns a concise summary of any text.",
    #           tags:        ["nlp", "text"]
    #
    #     auth_scheme :bearer_token  # or :api_key, :none
    #
    #     def handle_task(task_request, context)
    #       text = task_request.dig("params", "message", "parts", 0, "text") || ""
    #       context.update_status("working")
    #       part    = RubyA2A::Models::Part.text("You said: #{text}")
      #       message = RubyA2A::Models::Message.new("agent", [part])
    #       context.complete!(message)
    #     end
    #   end
    #
    class Executor
      # -----------------------------------------------------------------------
      # DSL — class-level declarations
      # -----------------------------------------------------------------------
      module ClassMethods
        def agent_name(value = nil)
          @agent_name = value if value
          @agent_name
        end

        def agent_description(value = nil)
          @agent_description = value if value
          @agent_description
        end

        def agent_url(value = nil)
          @agent_url = value if value
          @agent_url
        end

        def protocol_version(value = nil)
          @protocol_version = value if value
          @protocol_version || "0.2.1"
        end

        def capabilities(**opts)
          @capabilities = opts unless opts.empty?
          @capabilities || {}
        end

        def skill(**opts)
          @skills ||= []
          @skills << opts
        end

        def skills
          @skills || []
        end

        def auth_scheme(scheme = nil)
          @auth_scheme = scheme if scheme
          @auth_scheme || :none
        end

        # Builds and returns the Agent Card hash following the A2A spec.
        def agent_card_hash
          card = {
            "name"                => agent_name,
            "description"         => agent_description,
            "url"                 => agent_url,
            "version"             => protocol_version,
            "defaultInputModes"   => ["text"],
            "defaultOutputModes"  => ["text"],
            "capabilities"        => build_capabilities_hash,
            "skills"              => skills.map { |s| build_skill_hash(s) }
          }

          # Include securitySchemes only when auth is required
          unless auth_scheme == :none
            card["securitySchemes"] = build_security_schemes_hash
            card["security"]        = [{ auth_scheme.to_s => [] }]
          end

          card
        end

        private

        def build_capabilities_hash
          caps = {}
          @capabilities&.each do |k, v|
            # Convert snake_case keys to camelCase for A2A compliance
            caps[camelize(k.to_s)] = v
          end
          caps
        end

        def build_skill_hash(opts)
          h = {}
          h["id"]          = opts[:id].to_s              if opts[:id]
          h["name"]        = opts[:name].to_s            if opts[:name]
          h["description"] = opts[:description].to_s     if opts[:description]
          h["tags"]        = Array(opts[:tags])           if opts[:tags]
          h["inputModes"]  = Array(opts[:input_modes])   if opts[:input_modes]
          h["outputModes"] = Array(opts[:output_modes])  if opts[:output_modes]
          h["examples"]    = Array(opts[:examples])      if opts[:examples]
          h
        end

        def build_security_schemes_hash
          case auth_scheme
          when :bearer_token
            { "bearerAuth" => { "type" => "http", "scheme" => "bearer" } }
          when :api_key
            { "apiKeyAuth" => { "type" => "apiKey", "in" => "header", "name" => "X-API-Key" } }
          else
            {}
          end
        end

        def camelize(str)
          parts = str.split("_")
          parts[0] + parts[1..].map(&:capitalize).join
        end
      end

      extend ClassMethods

      # -----------------------------------------------------------------------
      # Instance — task handling
      # -----------------------------------------------------------------------

      # The single method subclasses must implement.
      #
      # @param task_request [Hash]        full JSON-RPC params hash from the client
      # @param context      [TaskContext] helper object to update state and complete
      def handle_task(task_request, context)
        raise NotImplementedError, "#{self.class}#handle_task is not implemented"
      end

      # Convenience accessor so executor instances can build models.
      def build_text_part(text)
        Models::Part.text(text)
      end

      def build_data_part(data)
        Models::Part.data(data)
      end

      def build_agent_message(*parts)
        Models::Message.new("agent", parts)
      end
    end

    # Passed to Executor#handle_task so the agent can drive the task lifecycle.
    class TaskContext
      attr_reader :task_id, :store, :sse_writer

      def initialize(task_id:, store:, sse_writer: nil)
        @task_id    = task_id
        @store      = store
        @sse_writer = sse_writer
      end

      # Transitions the task to a non-terminal state.
      # Optionally emits an SSE event when a writer is attached.
      #
      # @param state   [String]       A2A state string e.g. "working"
      # @param message [Hash, nil]    Optional status message hash with :text key
      def update_status(state, message: nil)
        status = { "state" => state.to_s }
        if message
          msg = message.dup
          msg["messageId"] ||= SecureRandom.uuid
          if msg.key?("text") && !msg.key?("parts")
            text = msg.delete("text")
            msg["parts"] = [{ "text" => text.to_s }]
          end
          msg["parts"] = Array(msg["parts"]) if msg["parts"]
          msg["role"] ||= "agent"
          status["message"] = msg
        end

        @store.update_task_status(@task_id, status)

        if @sse_writer
          event_data = {
            "taskId"    => @task_id,
            "contextId" => @store.get_task(@task_id)&.dig("contextId") || "",
            "status"    => status,
            "final"     => false
          }
          @sse_writer.call("TaskStatusUpdateEvent", event_data)
        end
      end

      # Emits an artifact chunk (used during streaming).
      #
      # @param artifact_id [String]
      # @param chunk       [String]
      def emit_artifact_chunk(artifact_id, chunk, index: 0, append: false, last_chunk: false)
        return unless @sse_writer

        event_data = {
          "taskId"    => @task_id,
          "contextId" => @store.get_task(@task_id)&.dig("contextId") || "",
          "artifact"  => {
            "artifactId" => artifact_id,
            "parts"      => [{ "text" => chunk }],
            "append"     => append
          },
          "lastChunk" => last_chunk
        }.compact
        @sse_writer.call("TaskArtifactUpdateEvent", event_data)
      end

      # Marks the task as completed and stores the final message as an artifact.
      #
      # @param message [Models::Message]
      def complete!(message)
        artifact = {
          "artifactId" => "artifact-#{@task_id}",
          "name"       => "response",
          "parts"      => message.to_h["parts"]
        }

        task = @store.get_task(@task_id)
        updated_task = (task || {}).merge(
          "status"    => { "state" => "completed" },
          "artifacts" => [artifact]
        )
        @store.save_task(updated_task)

        if @sse_writer
          # Send artifact update with the final content
          artifact_event = {
            "taskId"    => @task_id,
            "contextId" => updated_task["contextId"] || "",
            "artifact"  => artifact,
            "lastChunk" => true
          }
          @sse_writer.call("TaskArtifactUpdateEvent", artifact_event)

          # Then send status update
          status_event = {
            "taskId"    => @task_id,
            "contextId" => updated_task["contextId"] || "",
            "status"    => { "state" => "completed" },
            "final"     => true
          }
          @sse_writer.call("TaskStatusUpdateEvent", status_event)
        end

        updated_task
      end

      # Marks the task as failed.
      #
      # @param reason [String]
      def fail!(reason)
        status = { "state" => "failed", "message" => { "text" => reason } }
        @store.update_task_status(@task_id, status)

        if @sse_writer
          final_event = {
            "taskId" => @task_id,
            "status" => status,
            "final"  => true
          }
          @sse_writer.call("TaskStatusUpdateEvent", final_event)
        end
      end
    end
  end
end
