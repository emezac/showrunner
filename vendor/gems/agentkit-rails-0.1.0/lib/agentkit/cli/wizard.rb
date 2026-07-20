# frozen_string_literal: true

require "json"

module Agentkit
  module CLI
    # Interactive 7-phase Setup Wizard.
    # Guides the user through an assessment of their domain and produces
    # a domain_profile.json that the Generator uses to scaffold the app.
    #
    # Phases:
    #   1. Domain identity
    #   2. Primary work unit
    #   3. Actors & HITL level
    #   4. LLM providers & budget
    #   5. Required capabilities
    #   6. Memory & learning config
    #   7. Infrastructure
    class Wizard
      INDUSTRIES = %w[legal salud construccion agencia finanzas educacion otro].freeze
      HITL_LEVELS = %w[strict advisory silent].freeze
      LLM_PROVIDERS = %w[anthropic google openai ollama].freeze
      COST_TIERS = { "1" => "economy", "2" => "balanced", "3" => "premium" }.freeze
      FEATURES = %w[rag scraping scope_guard contracts content_gen financial_health].freeze

      def initialize(app_name)
        @app_name = app_name
        @profile  = {}
      end

      def run
        clear_screen
        banner

        phase1_identity
        phase2_work_unit
        phase3_actors
        phase4_llm_providers
        phase5_capabilities
        phase6_memory
        phase7_infrastructure

        finalize_profile
        @profile
      end

      private

      # ─── Phase 1: Domain Identity ─────────────────────────────────────────

      def phase1_identity
        section("Phase 1 / 7 — Domain Identity")

        @profile["app_name"] = @app_name
        @profile["industry"] = ask_choice(
          "What industry does your app serve?",
          INDUSTRIES
        )

        @profile["niche"] = ask(
          "Describe your niche or specialization (e.g. 'Corporate law firm in CDMX'):"
        )
      end

      # ─── Phase 2: Work Unit ───────────────────────────────────────────────

      def phase2_work_unit
        section("Phase 2 / 7 — Primary Work Unit")

        @profile["primary_entity"] = ask(
          "What is the central object of your business? (e.g. caso, paciente, obra, proyecto):"
        ).downcase.gsub(/\s+/, "_")

        fields = ask_multiselect(
          "What information does this object have when created?",
          %w[titulo descripcion cliente fecha documentos presupuesto notas]
        )
        @profile["entity_fields"] = fields

        has_sub = ask_yes_no("Does this object have sub-entities? (milestones, documents, etc.)")
        if has_sub
          subs = ask("List sub-entities (comma-separated, e.g. hito,documento,nota):")
          @profile["secondary_entities"] = subs.split(",").map(&:strip)
        else
          @profile["secondary_entities"] = []
        end

        has_states = ask_yes_no("Does this object have lifecycle states?")
        if has_states
          states = ask("List states (comma-separated, e.g. borrador,activo,cerrado):")
          @profile["lifecycle_states"] = states.split(",").map(&:strip)
        else
          @profile["lifecycle_states"] = []
        end
      end

      # ─── Phase 3: Actors & HITL ───────────────────────────────────────────

      def phase3_actors
        section("Phase 3 / 7 — Actors & Autonomy Level")

        roles = ask_multiselect(
          "Who uses the system? Select all roles:",
          %w[admin operador cliente supervisor gerente pasante]
        )
        @profile["user_roles"] = roles.empty? ? ["admin", "operador"] : roles

        puts "\nHITL (Human-in-the-Loop) levels:"
        puts "  strict    — every agent suggestion requires human approval"
        puts "  advisory  — suggestions are visible; auto-applied after 24h if not reviewed"
        puts "  silent    — agents log only; no UI interruption"
        @profile["hitl_level"] = ask_choice("Select autonomy level:", HITL_LEVELS)

        @profile["client_portal"] = ask_yes_no(
          "Does the external client have access to the system? (generates client portal)"
        )
      end

      # ─── Phase 4: LLM Providers ───────────────────────────────────────────

      def phase4_llm_providers
        section("Phase 4 / 7 — LLM Providers & Budget")

        providers = ask_multiselect(
          "Which API keys do you have available?",
          LLM_PROVIDERS
        )
        @profile["llm_providers"] = providers.empty? ? ["anthropic"] : providers

        @profile["default_provider"] = ask_choice(
          "Which is your preferred provider?",
          @profile["llm_providers"]
        )

        puts "\nEstimated monthly LLM budget:"
        puts "  1 — Economy   (< $50/month)   → fast models only"
        puts "  2 — Balanced  ($50-$200/month) → mix of fast + default"
        puts "  3 — Premium   (> $200/month)   → complex models available"
        tier_choice = ask("Select budget tier [1/2/3]: ").strip
        @profile["cost_tier"] = COST_TIERS.fetch(tier_choice, "balanced")

        assign_models_by_tier(@profile["default_provider"], @profile["cost_tier"])

        @profile["ollama_local"] = ask_yes_no(
          "Do you need local execution (no data sent to cloud)? (activates Ollama)"
        )
      end

      # ─── Phase 5: Capabilities ────────────────────────────────────────────

      def phase5_capabilities
        section("Phase 5 / 7 — Required Capabilities")

        selected = []

        puts "Answer yes/no to activate each capability:\n\n"

        capability_questions.each do |cap, question|
          answer = ask_yes_no(question)
          selected << cap if answer
        end

        @profile["features"] = selected
      end

      # ─── Phase 6: Memory ──────────────────────────────────────────────────

      def phase6_memory
        section("Phase 6 / 7 — Memory & Learning")

        puts "Expected records in year 1:"
        puts "  1 — Small  (< 100)"
        puts "  2 — Medium (100-1000)"
        puts "  3 — Large  (> 1000)"
        scale = ask("Select scale [1/2/3]: ").strip

        threshold, lists_param = case scale
        when "1" then [0.30, 50]
        when "3" then [0.20, 500]
        else          [0.25, 100]
        end

        cron_hour = ask("What hour should the dreaming cycle run? (0-23, default 2):").strip
        cron_hour = "2" if cron_hour.empty? || cron_hour.to_i > 23

        @profile["memory"] = {
          "embedding_model"          => embedding_model_for(@profile["default_provider"]),
          "dreaming_cron"            => "0 #{cron_hour} * * *",
          "consolidation_threshold"  => threshold,
          "ivfflat_lists"            => lists_param,
          "auto_consolidate"         => ask_yes_no("Auto-consolidate high-confidence memories?")
        }
      end

      # ─── Phase 7: Infrastructure ──────────────────────────────────────────

      def phase7_infrastructure
        section("Phase 7 / 7 — Infrastructure")

        multi = ask_yes_no("Single-tenant or multi-tenant? (yes = multi-tenant)")
        redis = ask_yes_no("Is Redis available? (required for Sidekiq background jobs)")
        python = ask_yes_no("Is Python 3.10+ available? (enables ML prediction features)")
        a2a = ask_yes_no("Expose agents via A2A protocol? (allows external systems to call your agents)")
        mcp = ask_yes_no("Expose agents via MCP server?")

        @profile["infra"] = {
          "multi_tenant" => multi,
          "redis"        => redis,
          "python_ml"    => python,
          "a2a_enabled"  => a2a,
          "mcp_enabled"  => mcp
        }
      end

      # ─── Finalize ─────────────────────────────────────────────────────────

      def finalize_profile
        profile_path = "domain_profile.json"
        File.write(profile_path, JSON.pretty_generate(@profile))

        puts ""
        puts "✅ Assessment complete! Profile saved to: #{profile_path}"
        puts ""
        puts JSON.pretty_generate(@profile)
        puts ""
      end

      # ─── Helpers ──────────────────────────────────────────────────────────

      def ask(prompt)
        print "  #{prompt} "
        $stdout.flush
        $stdin.gets.to_s.chomp
      end

      def ask_yes_no(prompt)
        loop do
          answer = ask("#{prompt} [y/n]:").downcase.strip
          return true  if %w[y yes si s].include?(answer)
          return false if %w[n no].include?(answer)
          puts "  Please enter y or n."
        end
      end

      def ask_choice(prompt, options)
        puts "  #{prompt}"
        options.each_with_index { |opt, i| puts "    #{i + 1}. #{opt}" }
        loop do
          input = ask("Choose [1-#{options.size}]:").strip.to_i
          return options[input - 1] if input.between?(1, options.size)
          puts "  Invalid choice."
        end
      end

      def ask_multiselect(prompt, options)
        puts "  #{prompt}"
        options.each_with_index { |opt, i| puts "    #{i + 1}. #{opt}" }
        puts "  Enter comma-separated numbers (e.g. 1,3,4) or press Enter to select all:"
        input = ask(">").strip

        return options if input.empty?

        indices = input.split(",").map { |n| n.strip.to_i - 1 }
        indices.filter_map { |i| options[i] if i >= 0 }
      end

      def section(title)
        puts ""
        puts "─" * 60
        puts "  #{title}"
        puts "─" * 60
        puts ""
      end

      def banner
        puts <<~BANNER
          ╔═══════════════════════════════════════════╗
          ║       AgentKit Rails — Setup Wizard       ║
          ║           v#{Agentkit::VERSION.ljust(32)}║
          ╚═══════════════════════════════════════════╝

          This wizard assesses your domain (~5 minutes) and generates
          a pre-configured Rails app with agents, memory, HITL, and more.

          App name: #{@app_name}
        BANNER
      end

      def clear_screen
        system("clear") || system("cls")
      end

      def capability_questions
        {
          "rag"             => "Do users upload documents (PDFs, contracts, reports)?",
          "scraping"        => "Do you need to enrich profiles from LinkedIn/web?",
          "scope_guard"     => "Can project scope change unexpectedly? (activate ScopeCreepDetection)",
          "contracts"       => "Do you manage contracts and charge for scope changes?",
          "content_gen"     => "Do you need to generate posts, reports, or exportable documents?",
          "financial_health" => "Do you want monthly LLM cost monitoring alerts?"
        }
      end

      def assign_models_by_tier(provider, tier)
        models = case [provider, tier]
        when ["anthropic", "economy"]
          { default: "claude-haiku-4-5", fast: "claude-haiku-4-5", complex: "claude-sonnet-4-6" }
        when ["anthropic", "premium"]
          { default: "claude-sonnet-4-6", fast: "claude-haiku-4-5", complex: "claude-opus-4-6" }
        when ["anthropic", "balanced"]
          { default: "claude-sonnet-4-6", fast: "claude-haiku-4-5", complex: "claude-sonnet-4-6" }
        when ["google", "economy"]
          { default: "gemini-2.5-flash", fast: "gemini-2.5-flash", complex: "gemini-2.0-pro" }
        when ["google", "balanced"]
          { default: "gemini-2.5-flash", fast: "gemini-2.5-flash", complex: "gemini-2.0-pro" }
        when ["google", "premium"]
          { default: "gemini-2.0-pro", fast: "gemini-2.5-flash", complex: "gemini-2.0-pro" }
        when ["openai", "economy"]
          { default: "gpt-4o-mini", fast: "gpt-4o-mini", complex: "gpt-4o" }
        when ["openai", "balanced"]
          { default: "gpt-4o", fast: "gpt-4o-mini", complex: "gpt-4o" }
        when ["openai", "premium"]
          { default: "gpt-4o", fast: "gpt-4o-mini", complex: "o1" }
        else
          { default: "claude-sonnet-4-6", fast: "gemini-2.5-flash", complex: "claude-opus-4-6" }
        end

        @profile["default_model"] = models[:default]
        @profile["fast_model"]    = models[:fast]
        @profile["complex_model"] = models[:complex]
      end

      def embedding_model_for(provider)
        case provider
        when "google"    then "gemini-embedding-2"
        when "openai"    then "text-embedding-3-small"
        when "anthropic" then "gemini-embedding-2"  # Anthropic doesn't offer embeddings
        else "gemini-embedding-2"
        end
      end
    end
  end
end
