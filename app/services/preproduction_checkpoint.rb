# frozen_string_literal: true

require "digest"
require "json"
require "active_support/security_utils"

# Persists paid pre-production work after each durable stage. A Sidekiq retry
# can resume from the last completed stage instead of charging for screenplay,
# canonical assets or storyboard frames again. Looking the project up for every
# checkpoint also provides cooperative cancellation when it is deleted.
class PreproductionCheckpoint
  VERSION = "1.0"
  STAGES = %w[screenplay assets storyboard visual_qa completed].freeze
  CONTRACT_DIRECTION_KEYS = %w[
    adaptation_mode pipeline_mode genre audience camera_style color_grade
    music_style voice_style max_scenes director_influence force_story force_domain
  ].freeze

  class << self
    def active!(project_id)
      Project.find(project_id)
    end

    def stage_for(project)
      checkpoint = project.manifest.to_h.with_indifferent_access["preproduction_checkpoint"].to_h
      return unless checkpoint["version"] == VERSION
      return unless secure_match?(checkpoint["input_digest"], input_digest(project))

      checkpoint["stage"] if STAGES.include?(checkpoint["stage"].to_s)
    end

    def reached?(current_stage, required_stage)
      current_index = STAGES.index(current_stage.to_s)
      required_index = STAGES.index(required_stage.to_s)
      current_index.present? && required_index.present? && current_index >= required_index
    end

    def persist!(project_id:, stage:, ledger:, data: {})
      raise ArgumentError, "unknown pre-production stage #{stage}" unless STAGES.include?(stage.to_s)

      Project.transaction do
        project = Project.lock.find(project_id)
        manifest = (project.manifest || {}).with_indifferent_access
        data.to_h.each { |key, value| manifest[key.to_s] = value }
        manifest["budget_ledger"] = serializable_ledger(ledger)
        manifest["preproduction_checkpoint"] = {
          "version" => VERSION,
          "stage" => stage.to_s,
          "input_digest" => input_digest(project),
          "saved_at" => Time.current.iso8601
        }

        project.assign_attributes(
          manifest: manifest,
          tokens_used: ledger_value(ledger, :tokens_used, project.tokens_used).to_i,
          tokens_remaining: ledger_value(ledger, :tokens_remaining, project.tokens_remaining).to_i,
          video_credits_used: ledger_value(ledger, :video_credits_used, project.video_credits_used).to_i
        )
        project.save!
        project
      end
    end

    def input_digest(project)
      direction = project.direction.to_h.slice(*CONTRACT_DIRECTION_KEYS)
      payload = {
        "prompt" => project.prompt.to_s,
        "duration" => project.duration.to_i,
        "resolution" => project.resolution.to_s,
        "seed" => project.seed.to_i,
        "dry_run" => project.dry_run?,
        "direction" => direction
      }
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
    end

    private

    def ledger_value(ledger, key, fallback)
      ledger.to_h[key] || ledger.to_h[key.to_s] || fallback
    end

    def serializable_ledger(ledger)
      ledger.to_h.deep_stringify_keys.except("allow_token_overrun")
    end

    def secure_match?(left, right)
      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    rescue ArgumentError
      false
    end

    def canonicalize(value)
      case value
      when Hash
        value.to_h.to_a.sort_by { |key, _item| key.to_s }.to_h do |key, item|
          [key.to_s, canonicalize(item)]
        end
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end
  end
end
