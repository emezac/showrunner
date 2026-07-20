# frozen_string_literal: true

module AgentSketch
  module A2A
    # Exposes an AgentSketch workflow as a Google A2A-compatible HTTP server.
    #
    # Usage (via DSL):
    #   AgentSketch.serve_a2a(port: 4567, name: "My Research Agent") do
    #     agent :researcher do ... end
    #     agent :writer     do ... end
    #     workflow { researcher >> writer }
    #   end
    #
    # Or instantiate directly:
    #   server = AgentSketch::A2A::Server.new(plan, port: 4567, ...)
    #   server.start
    class Server
      DEFAULT_PROTOCOL_VERSION = "0.2.1"

      def initialize(plan, port: 4567, host: "localhost",
                     name: "AgentSketch Agent",
                     description: "Multi-agent workflow powered by AgentSketch",
                     version: DEFAULT_PROTOCOL_VERSION,
                     skills: [])
        @plan        = plan
        @port        = port
        @host        = host
        @name        = name
        @description = description
        @version     = version
        @skills      = skills.empty? ? default_skills : skills
        @task_store  = TaskStore.new
      end

      def start
        require_ruby_a2a!

        executor = build_executor
        store    = RubyA2A::Server::TaskStore::InMemory.new

        http_server = RubyA2A::Server::HttpServer.new(
          executor: executor,
          store:    store,
          port:     @port,
          host:     @host
        )

        print_banner
        setup_signals(http_server)
        http_server.start
      end

      # Build a Rack app for use with custom servers (Puma, Falcon, etc.)
      # @return [Rack app]
      def to_rack_app
        require_ruby_a2a!

        executor = build_executor
        store    = RubyA2A::Server::TaskStore::InMemory.new
        RubyA2A::Server::RackApp.new(executor: executor, store: store)
      end

      private

      def require_ruby_a2a!
        require "ruby_a2a"
        require "ruby_a2a/server"
      rescue LoadError
        raise AgentSketch::ConfigurationError,
              "La gema 'ruby-a2a' es necesaria para serve_a2a. " \
              "Añade: gem 'ruby-a2a' en tu Gemfile"
      end

      def build_executor
        plan        = @plan
        agent_name  = @name
        agent_desc  = @description
        agent_url   = "http://#{@host}:#{@port}"
        proto       = @version
        skills_list = @skills

        # Dynamically build the executor class using ruby-a2a DSL
        klass = Class.new(RubyA2A::Server::Executor) do
          agent_name        agent_name
          agent_description agent_desc
          agent_url         agent_url
          protocol_version  proto
          capabilities      streaming: false, push_notifications: false

          skills_list.each do |skill|
            skill id:          skill[:id],
                  name:        skill[:name],
                  description: skill[:description],
                  tags:        skill[:tags] || [],
                  examples:    skill[:examples] || []
          end

          define_method(:handle_task) do |params, context|
            # Extract user message text from A2A params
            input_text = params.dig("message", "parts", 0, "text") ||
                         params.dig("message", "parts", 0, "content") ||
                         ""

            context.update_status("working",
              message: { "text" => "Procesando con AgentSketch..." })

            # Run the AgentSketch workflow
            runner = AgentSketch::Runner.new(plan, { verbose: false })
            result = runner.run(input_text)

            if result.success?
              reply_part = build_text_part(result.output.to_s)
              reply_msg  = build_agent_message(reply_part)
              context.complete!(reply_msg)
            else
              errors = result.errors.map { |e| e[:error].to_s }.join("; ")
              context.update_status("failed",
                message: { "text" => "Error en workflow: #{errors}" })
            end
          end
        end

        klass.new
      end

      def default_skills
        # Auto-generate skills from defined agents
        @plan.agents.map do |id, defn|
          {
            id:          id.to_s,
            name:        "Agente #{id.to_s.capitalize}",
            description: defn.role,
            tags:        defn.tools.map { |t| t.name.to_s },
            examples:    []
          }
        end
      end

      def print_banner
        puts "=" * 60
        puts "  AgentSketch A2A Server"
        puts "  Nombre      : #{@name}"
        puts "  Escuchando  : http://#{@host}:#{@port}"
        puts "  Agent Card  : GET  http://#{@host}:#{@port}/.well-known/agent.json"
        puts "  RPC         : POST http://#{@host}:#{@port}/"
        puts "  Agentes     : #{@plan.agents.keys.join(', ')}"
        puts "=" * 60
        puts
        puts "  Prueba rápida:"
        puts "  curl -X POST http://#{@host}:#{@port}/ \\"
        puts "    -H 'Content-Type: application/json' \\"
        puts "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{\"message\":{\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"Hola, empieza el workflow\"}]}}}'"
        puts "=" * 60
      end

      def setup_signals(server)
        trap("INT")  { puts "\nApagando AgentSketch A2A server..."; server.shutdown }
        trap("TERM") { puts "\nApagando AgentSketch A2A server..."; server.shutdown }
      end

      # Simple in-process task store (used internally before delegating to ruby-a2a)
      class TaskStore
        def initialize
          @tasks = {}
          @mutex = Mutex.new
        end

        def store(task_id, data)
          @mutex.synchronize { @tasks[task_id] = data }
        end

        def fetch(task_id)
          @mutex.synchronize { @tasks[task_id] }
        end

        def all
          @mutex.synchronize { @tasks.dup }
        end
      end
    end
  end
end
