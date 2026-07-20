# frozen_string_literal: true

require "showrunner"

# Re-runs storyboard vision QA without spending image credits or changing the
# approved keyframes. This is the recovery path when planning exhausted the
# text-token budget after image generation had already completed.
class StoryboardVisualQaRefresher
  class << self
    def refresh!(project:, manifest:, allow_token_overrun: false,
                 evaluator: VisualConsistencyEvaluator, config: QwenRouter::Config.default)
      manifest = manifest.with_indifferent_access
      assets = (manifest["assets"] || {}).with_indifferent_access
      screenplay = (manifest["screenplay"] || {}).with_indifferent_access
      ledger = {
        tokens_used: project.tokens_used.to_i,
        tokens_remaining: project.tokens_remaining.to_i,
        token_budget: project.token_budget.to_i,
        tokens_over_budget: [project.tokens_used.to_i - project.token_budget.to_i, 0].max,
        allow_token_overrun: allow_token_overrun == true,
        video_credits_used: project.video_credits_used.to_i,
        calls: []
      }

      production_bible = ProductionBible.compile(
        screenplay: screenplay, assets: assets, selection: nil, original_prompt: project.prompt
      )
      screenplay = ContinuityPlanner.plan!(screenplay, production_bible)
      screenplay = ConsistencyEnforcer.apply!(
        screenplay, nil, assets, rich_prompt: true, production_bible: production_bible
      )
      script_report = screenplay["script_consistency_report"] || {}
      if script_report["ready"] == false
        raise "Script consistency must be resolved before visual QA can run"
      end

      visual = evaluator.evaluate(
        screenplay: screenplay,
        production_bible: production_bible,
        ledger: ledger,
        config: config
      )
      report = ConsistencyEvaluator.evaluate(
        screenplay: screenplay,
        production_bible: production_bible,
        assets: assets,
        strict_references: !project.dry_run?
      )
      report["visual_metrics"] = visual
      attach_visual_result!(report, visual, require_visual: !project.dry_run?)

      ledger.delete(:allow_token_overrun)
      ledger[:overrun_authorized] = allow_token_overrun == true
      manifest["screenplay"] = screenplay
      manifest["production_bible"] = production_bible
      manifest["consistency_report"] = report
      manifest["budget_ledger"] = ledger
      manifest.delete("visual_qa_override")

      {
        "manifest" => manifest,
        "consistency_report" => report,
        "ledger" => ledger,
        "images" => [],
        "asset_images" => [],
        "errors" => visual["status"] == "measured" ? [] : [visual["reason"].to_s],
        "skipped_shot_ids" => [],
        "changed_asset_ids" => [],
        "generated_at" => Time.current.to_f
      }
    end

    private

    def attach_visual_result!(report, visual, require_visual:)
      if require_visual && visual["status"] != "measured"
        add_critical!(report, nil, "visual_audit_unavailable", "Storyboard visual fidelity could not be fully measured")
      elsif require_visual
        Array(visual["failed_shot_ids"]).each do |shot_id|
          add_critical!(report, shot_id, "visual_consistency_failed", "Storyboard keyframe violates a hard visual consistency dimension")
        end
      end
      report["ready_for_render"] = report["critical_count"].zero?
    end

    def add_critical!(report, shot_id, code, message)
      report["critical_count"] = report["critical_count"].to_i + 1
      report["issues"] << {
        "severity" => "critical", "shot_id" => shot_id, "code" => code, "message" => message
      }
    end
  end
end
