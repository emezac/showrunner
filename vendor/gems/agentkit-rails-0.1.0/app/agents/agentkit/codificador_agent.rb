# frozen_string_literal: true

module Agentkit
  # Generates Rails code for an accepted EvolutionItem.
  # Produces one or more CodeGeneration records per item.
  # A developer reviews the generated code in the Fábrica UI before applying.
  #
  # Called by EvolutionItem#accept! via AgentWorkerJob.
  class CodificadorAgent < ApplicationAgent
    def call(evolution_item)
      evolution_item.start_coding!

      generated_files = generate_code_for(evolution_item)

      generated_files.each do |file_spec|
        Agentkit::CodeGeneration.create!(
          evolution_item:  evolution_item,
          target_file:     file_spec[:target_file],
          generated_code:  file_spec[:code],
          explanation:     file_spec[:explanation],
          status:          "draft",
          user:            current_user
        )
      end

      agent_log(
        event:   "completed",
        payload: {
          evolution_item_id: evolution_item.id,
          files_generated:   generated_files.size
        }
      )
    rescue StandardError => e
      evolution_item.update!(status: "rejected")
      agent_log(event: "failed", payload: { error: e.message })
      raise
    end

    private

    def generate_code_for(item)
      prompt = <<~PROMPT
        You are an expert Rails 8 developer generating production-quality code.
        Domain: #{Agentkit.config.domain_name}
        Primary entity: #{Agentkit.config.primary_entity}

        Generate the code for the following improvement:
        Type: #{item.item_type}
        Title: #{item.title}
        Description: #{item.description}
        Rationale: #{item.rationale}

        Output a JSON array of file objects. Each object:
        {
          "target_file": "app/models/caso.rb",       // relative to Rails root
          "code": "# frozen_string_literal: true\n...",
          "explanation": "What this file does and why"
        }

        Rules:
        - Output valid Ruby following Rails 8 conventions
        - frozen_string_literal: true on every file
        - Use Agentkit::AgentTriggerable for new models if appropriate
        - Include validations, scopes, and associations
        - Output JSON array only, no markdown fences
      PROMPT

      raw = chat(prompt, model: :code)
      JSON.parse(raw)
    rescue JSON::ParserError => e
      Rails.logger.error("[AgentKit::CodificadorAgent] JSON parse error: #{e.message}")
      []
    end
  end
end
