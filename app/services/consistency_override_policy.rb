# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "active_support/security_utils"

# Allows a producer to explicitly accept visual-QA risk for one render without
# weakening narrative or canonical-asset contracts. The authorization is bound
# to the exact set of current keyframes, is consumed when the render starts and
# covers both storyboard QA and the final video QA result for that run.
class ConsistencyOverridePolicy
  RENDER_SCOPE = "next_render_visual_qa".freeze
  LEGACY_SCOPE = "storyboard_visual_qa_only".freeze
  LEGACY_CLIP_RECOVERY_SCOPE = "next_targeted_video_recovery".freeze
  OVERRIDABLE_CODES = %w[
    visual_audit_unavailable
    visual_audit_required
    visual_consistency_failed
  ].freeze

  class << self
    def overrideable?(report)
      critical = Array(report&.dig("issues")).select { |issue| issue["severity"] == "critical" }
      critical.any? && critical.all? { |issue| OVERRIDABLE_CODES.include?(issue["code"].to_s) }
    end

    def authorize!(manifest:, screenplay:)
      manifest["visual_qa_override"] = {
        "authorized" => true,
        "scope" => RENDER_SCOPE,
        "storyboard_digest" => storyboard_digest(screenplay),
        "authorized_at" => Time.current.iso8601
      }
    end

    def valid?(manifest:, screenplay:)
      source = manifest.to_h
      authorization = (source["visual_qa_override"] || source[:visual_qa_override]).to_h
      ActiveRecord::Type::Boolean.new.cast(authorization["authorized"]) &&
        [RENDER_SCOPE, LEGACY_SCOPE].include?(authorization["scope"]) &&
        ActiveSupport::SecurityUtils.secure_compare(
          authorization["storyboard_digest"].to_s,
          storyboard_digest(screenplay)
        )
    rescue ArgumentError
      false
    end

    def apply!(report:, manifest:, screenplay:)
      return false unless overrideable?(report) && valid?(manifest: manifest, screenplay: screenplay)

      report["ready_for_render"] = true
      report["visual_qa_override"] = manifest["visual_qa_override"].merge("applied" => true)
      report["warnings"] = Array(report["warnings"]) + [
        "Producer explicitly accepted visual-QA risk for this exact keyframe set and its next video render."
      ]
      true
    end

    def render_contract_digest(manifest)
      source = manifest.to_h.with_indifferent_access
      screenplay = source["screenplay"].to_h
      assets = source["assets"].to_h
      shots = Array(screenplay["scenes"]).flat_map { |scene| Array(scene["shots"]) }
      payload = {
        shots: shots.map do |shot|
          shot.to_h.slice(
            "id", "image_url", "visual_prompt", "negative_prompt", "duration",
            "continuity", "story_event", "initial_state", "final_state"
          )
        end,
        assets: %w[characters props locations].to_h do |type|
          [type, Array(assets[type]).map { |asset| asset.to_h.except("image_url_expires_at") }]
        end,
        edit_decision_list: source["edit_decision_list"] || screenplay["edit_decision_list"]
      }
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
    end

    def storyboard_digest(screenplay)
      shots = Array(screenplay&.dig("scenes")).flat_map { |scene| Array(scene["shots"]) }
      payload = shots.map { |shot| [shot["id"].to_s, shot["image_url"].to_s] }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def render_checkpoint_matches?(manifest:, project_updated_at:)
      source = manifest.to_h.with_indifferent_access
      checkpoint = source["pending_video_review"].to_h
      stored = checkpoint["render_contract_digest"].to_s
      current = render_contract_digest(source)
      return true if stored.present? && ActiveSupport::SecurityUtils.secure_compare(stored, current)

      legacy_checkpoint_unchanged?(manifest: source, project_updated_at: project_updated_at)
    rescue ArgumentError
      false
    end

    def legacy_checkpoint_unchanged?(manifest:, project_updated_at:)
      source = manifest.to_h.with_indifferent_access
      checkpoint = source["pending_video_review"].to_h
      return false unless ActiveRecord::Type::Boolean.new.cast(checkpoint["available"])
      return false if checkpoint["created_at"].blank? || checkpoint["video_sha256"].blank?
      return false unless Array(source["video_jobs"]).any? { |job| job.to_h.with_indifferent_access["task_id"].present? }

      created_at = Time.iso8601(checkpoint["created_at"].to_s)
      (project_updated_at.to_time - created_at).abs <= 2.seconds
    rescue ArgumentError, TypeError
      false
    end

    def authorize_legacy_clip_recovery!(manifest:)
      source = manifest.to_h.with_indifferent_access
      checkpoint = source["pending_video_review"].to_h
      manifest["legacy_clip_recovery"] = {
        "authorized" => true,
        "scope" => LEGACY_CLIP_RECOVERY_SCOPE,
        "render_contract_digest" => render_contract_digest(source),
        "video_sha256" => checkpoint["video_sha256"],
        "authorized_at" => Time.current.iso8601
      }
    end

    def legacy_clip_recovery_valid?(manifest:)
      source = manifest.to_h.with_indifferent_access
      authorization = source["legacy_clip_recovery"].to_h
      checkpoint = source["pending_video_review"].to_h
      ActiveRecord::Type::Boolean.new.cast(authorization["authorized"]) &&
        authorization["scope"] == LEGACY_CLIP_RECOVERY_SCOPE &&
        ActiveSupport::SecurityUtils.secure_compare(
          authorization["render_contract_digest"].to_s,
          render_contract_digest(source)
        ) &&
        ActiveSupport::SecurityUtils.secure_compare(
          authorization["video_sha256"].to_s,
          checkpoint["video_sha256"].to_s
        )
    rescue ArgumentError
      false
    end

    private

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
