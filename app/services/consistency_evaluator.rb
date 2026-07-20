# frozen_string_literal: true

# Preflight gate for render consistency. This deliberately reports what can be
# verified from the production contract and never claims to have measured
# pixels. Pixel/face/object metrics can be appended under `visual_metrics` by a
# future vision worker without changing the manifest contract.
require_relative "asset_fidelity_evaluator"
require "stable_media"

class ConsistencyEvaluator
  class << self
    def evaluate(screenplay:, production_bible:, assets:, strict_references: false)
      issues = []
      fidelity = AssetFidelityEvaluator.evaluate(
        source_prompt: production_bible&.dig("source_prompt"),
        source_profiles: production_bible&.dig("source_profiles"),
        assets: assets
      )
      issues.concat(Array(fidelity["issues"]))
      entities = ProductionBible.entity_index(production_bible)
      shots = Array(screenplay["scenes"]).flat_map { |scene| Array(scene["shots"]) }
      script_report = screenplay["script_consistency_report"] || {}
      Array(script_report["issues"]).each do |script_issue|
        next unless script_issue["severity"] == "critical"

        issues << issue("critical", script_issue["shot_id"], script_issue["code"], script_issue["message"])
      end

      shots.each do |shot|
        continuity = shot["continuity"]
        if continuity.blank?
          issues << issue("critical", shot["id"], "missing_continuity_plan", "Shot has no continuity state")
          next
        end

        required = Array(continuity["required_entity_ids"])
        unknown = required.reject { |id| entities.key?(id.to_s) }
        if unknown.any?
          issues << issue("critical", shot["id"], "unknown_entities", "Unknown canonical entities: #{unknown.join(', ')}")
        end

        if required.none? { |id| entities.dig(id.to_s, "type") != "location" }
          issues << issue("warning", shot["id"], "no_subject_or_prop", "Shot has no bound character or prop")
        end

        if continuity["physical_constraints"].blank?
          issues << issue("warning", shot["id"], "missing_physics", "Shot has no physical constraints")
        end

        strategy = continuity["render_strategy"]
        approved_keyframe_available = [shot["image_url"], shot["stable_image_url"]].compact.any? do |url|
          remote_url?(url)
        end
        if strategy == "keyframe_i2v" && !approved_keyframe_available
          severity = strict_references ? "critical" : "warning"
          issues << issue(severity, shot["id"], "missing_keyframe", "I2V strategy has no remote approved keyframe")
        end
      end

      Array(production_bible&.dig("entities")).each do |entity|
        next if entity["type"] == "location"
        references = Array(entity["reference_images"]) + Array(entity["stable_reference_images"])
        next if references.any? { |url| remote_url?(url) }

        severity = strict_references && entity["is_primary"] ? "critical" : "warning"
        issues << issue(severity, nil, "missing_reference", "#{entity['id']} has no remote canonical reference")
      end

      critical = issues.count { |item| item["severity"] == "critical" }
      warnings = issues.count { |item| item["severity"] == "warning" }
      structural_score = [[100 - (critical * 35) - (warnings * 5), 0].max, 100].min

      {
        "version" => "1.0",
        "ready_for_render" => critical.zero?,
        "structural_score" => structural_score,
        "shots_evaluated" => shots.size,
        "critical_count" => critical,
        "warning_count" => warnings,
        "issues" => issues,
        "asset_fidelity" => fidelity,
        "script_consistency" => script_report,
        "visual_metrics" => {
          "status" => "not_measured",
          "reason" => "requires post-generation vision analysis"
        }
      }
    end

    private

    def issue(severity, shot_id, code, message)
      { "severity" => severity, "shot_id" => shot_id, "code" => code, "message" => message }
    end

    def remote_url?(value)
      StableMedia.reference?(value)
    end
  end
end
