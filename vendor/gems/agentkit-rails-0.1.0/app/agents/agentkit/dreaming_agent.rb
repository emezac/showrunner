# frozen_string_literal: true

module Agentkit
  # Runs during the nightly dreaming cycle to:
  #   1. Cluster raw embedded memories by semantic similarity
  #   2. Synthesize each cluster into a higher-level insight or pattern
  #   3. Mark consolidated memories as "consolidated" and archive the originals
  #   4. Optionally auto-consolidate if Agentkit.config.auto_consolidate is true
  #
  # Called by DreamingJob — instantiated per user.
  class DreamingAgent < ApplicationAgent
    def call
      clusters = Agentkit::MemoryEngine.cluster_raw(
        user:      current_user,
        account:   current_account,
        threshold: Agentkit.config.dreaming_threshold
      )

      return if clusters.empty?

      Rails.logger.info(
        "[AgentKit::DreamingAgent] Processing #{clusters.size} clusters for user #{current_user.id}"
      )

      clusters.each { |cluster| process_cluster(cluster) }
    end

    private

    def process_cluster(memories)
      content_block = memories.map.with_index(1) do |m, i|
        "[#{i}] #{m.content}"
      end.join("\n")

      prompt = <<~PROMPT
        You are analyzing a cluster of related agent memories.
        Synthesize these #{memories.size} observations into a single high-level insight or pattern.
        Be concise (2-4 sentences). Output only the synthesized text, no preamble.

        Memories:
        #{content_block}
      PROMPT

      synthesis = chat(prompt, model: :default)

      avg_confidence = memories.sum(&:confidence) / memories.size
      all_tags       = memories.flat_map(&:tags).uniq

      consolidated = memorize!(
        synthesis,
        tags:       all_tags + ["consolidated"],
        type:       "insight",
        confidence: [avg_confidence + 0.05, 1.0].min
      )

      # Archive originals
      Agentkit::Memory.where(id: memories.map(&:id)).update_all(status: "archived")

      agent_log(
        event:   "memorized",
        payload: {
          action:         "consolidated",
          cluster_size:   memories.size,
          memory_ids:     memories.map(&:id),
          new_memory_id:  consolidated.id
        }
      )
    end
  end
end
