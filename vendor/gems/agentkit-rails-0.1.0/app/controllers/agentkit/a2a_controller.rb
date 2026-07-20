# frozen_string_literal: true

module Agentkit
  # Exposes the AgentKit kernel as an A2A (Agent-to-Agent) server.
  # Mounted at /agentkit/a2a when a2a_enabled: true in config.
  #
  # Protocol: JSON-RPC 2.0 over HTTP POST
  # Auth:     X-A2A-Key header must match Agentkit.config.a2a_secret_key
  #
  # Supported methods (agent cards):
  #   memory_query        — semantic search over memories
  #   suggestion_resolver — approve / reject a suggestion
  #   risk_assessor       — risk score for a domain entity
  #   velocity_predictor  — velocity vs milestones
  #   client_enricher     — enrich client data from web
  #   contract_addendum   — generate addendum for scope change
  #   dreaming_summary    — summary of last dreaming cycle
  class A2aController < ActionController::API
    before_action :verify_feature_enabled
    before_action :authenticate_a2a_request

    # GET /.well-known/agent.json — A2A agent card discovery
    def agent_card
      render json: {
        name:        "#{Agentkit.config.domain_name} AgentKit",
        description: "AgentKit Rails kernel — #{Agentkit.config.primary_entity} domain",
        version:     Agentkit::VERSION,
        protocol:    "a2a/1.0",
        methods:     supported_methods
      }
    end

    # POST / — JSON-RPC 2.0 dispatch
    def dispatch
      body   = parse_body
      method = body["method"]
      params = body["params"] || {}
      id     = body["id"]

      result = dispatch_method(method, params)
      render json: { jsonrpc: "2.0", id: id, result: result }
    rescue ArgumentError => e
      render json: jsonrpc_error(-32_602, e.message, body&.fetch("id", nil))
    rescue StandardError => e
      render json: jsonrpc_error(-32_603, e.message, body&.fetch("id", nil))
    end

    private

    # ─── Method dispatch ──────────────────────────────────────────────────────

    def dispatch_method(method, params)
      case method
      when "memory_query"        then handle_memory_query(params)
      when "suggestion_resolver" then handle_suggestion_resolver(params)
      when "risk_assessor"       then handle_risk_assessor(params)
      when "velocity_predictor"  then handle_velocity_predictor(params)
      when "client_enricher"     then handle_client_enricher(params)
      when "contract_addendum"   then handle_contract_addendum(params)
      when "dreaming_summary"    then handle_dreaming_summary
      else raise ArgumentError, "Unknown method: #{method}"
      end
    end

    # ─── Agent card handlers ──────────────────────────────────────────────────

    def handle_memory_query(params)
      query = params.fetch("query") { raise ArgumentError, "query required" }
      user  = resolve_user(params["user_id"])

      memories = Agentkit::MemoryEngine.search(query: query, user: user, k: 5)
      memories.map do |m|
        { id: m.id, content: m.content, type: m.memory_type,
          confidence: m.confidence, tags: m.tags }
      end
    end

    def handle_suggestion_resolver(params)
      suggestion_id = params.fetch("suggestion_id") { raise ArgumentError, "suggestion_id required" }
      action        = params.fetch("action") { raise ArgumentError, "action required" }
      user          = resolve_user(params["user_id"])

      case action
      when "approve" then Agentkit::HITLEngine.approve(suggestion_id, user: user)
      when "reject"  then Agentkit::HITLEngine.reject(suggestion_id, user: user)
      when "snooze"  then Agentkit::HITLEngine.snooze(suggestion_id, user: user)
      else raise ArgumentError, "Unknown action: #{action}"
      end

      { status: "ok", suggestion_id: suggestion_id, action: action }
    end

    def handle_risk_assessor(params)
      entity_id   = params.fetch("entity_id")   { raise ArgumentError, "entity_id required" }
      entity_type = params.fetch("entity_type")  { raise ArgumentError, "entity_type required" }
      user        = resolve_user(params["user_id"])

      record = entity_type.constantize.find(entity_id)
      agent  = Agentkit::ApplicationAgent.new(user: user)

      prompt = "Assess the risk level for this #{entity_type}: #{record.attributes.to_json}. " \
               "Return JSON: { risk_score: 0-10, factors: [...], recommendation: '...' }"
      result = agent.chat(prompt, model: :complex)

      JSON.parse(result)
    rescue JSON::ParserError
      { risk_score: nil, raw: result }
    end

    def handle_velocity_predictor(params)
      entity_id = params.fetch("entity_id") { raise ArgumentError, "entity_id required" }
      user      = resolve_user(params["user_id"])

      # Domain must expose a velocity_data method or similar
      { entity_id: entity_id, message: "velocity_predictor requires domain implementation" }
    end

    def handle_client_enricher(params)
      client_id = params.fetch("client_id") { raise ArgumentError, "client_id required" }
      { client_id: client_id, message: "client_enricher requires :scraping feature" }
    end

    def handle_contract_addendum(params)
      { message: "contract_addendum requires :contracts feature" }
    end

    def handle_dreaming_summary
      last_log = Agentkit::AgentLog
        .for_agent("Agentkit::DreamingAgent")
        .where(event_type: "completed")
        .order(created_at: :desc)
        .first

      return { summary: "No dreaming cycles recorded yet." } unless last_log

      {
        last_run:     last_log.created_at,
        duration_ms:  last_log.duration_ms,
        payload:      last_log.payload
      }
    end

    # ─── Auth & helpers ───────────────────────────────────────────────────────

    def verify_feature_enabled
      unless Agentkit.config.a2a_enabled
        render json: { error: "A2A is not enabled" }, status: :not_found
      end
    end

    def authenticate_a2a_request
      secret = Agentkit.config.a2a_secret_key
      return if secret.blank? # No auth configured — open (dev mode)

      provided = request.headers["X-A2A-Key"]
      unless ActiveSupport::SecurityUtils.secure_compare(provided.to_s, secret)
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def parse_body
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      raise ArgumentError, "Invalid JSON body"
    end

    def resolve_user(user_id)
      user_id ? User.find(user_id) : User.first
    end

    def supported_methods
      %w[
        memory_query suggestion_resolver risk_assessor
        velocity_predictor client_enricher contract_addendum dreaming_summary
      ]
    end

    def jsonrpc_error(code, message, id)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end
  end
end
