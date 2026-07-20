# frozen_string_literal: true

require "showrunner"

# Regenerates canonical references and storyboard frames as one consistency
# transaction. A request is never reported as successful when the provider did
# not return a new image, and every successful run refreshes visual QA.
class StoryboardRegenerator
  MIN_VISUAL_QA_TOKENS = 900
  VISUAL_QA_TOKENS_PER_SHOT = 150

  class << self
    def regenerate!(project:, manifest:, shot_ids:, respect_locks: true, client: nil,
                    evaluator: VisualConsistencyEvaluator, qwen_config: QwenRouter::Config.default,
                    allow_token_overrun: false)
      manifest = manifest.with_indifferent_access
      assets = (manifest["assets"] || {}).with_indifferent_access
      screenplay = (manifest["screenplay"] || {}).with_indifferent_access
      ledger = {
        tokens_used: project.tokens_used.to_i,
        tokens_remaining: project.tokens_remaining.presence || project.token_budget,
        token_budget: project.token_budget.to_i,
        tokens_over_budget: [project.tokens_used.to_i - project.token_budget.to_i, 0].max,
        allow_token_overrun: allow_token_overrun == true,
        video_credits_used: project.video_credits_used.to_i,
        calls: []
      }
      ensure_project_visual_budget!(
        project: project, shot_count: Array(shot_ids).uniq.size, allow_token_overrun: allow_token_overrun
      ) unless project.dry_run?
      screenplay = ScreenplayPlanner.upgrade!(screenplay, target_duration: project.duration, max_scenes: nil, seed: project.seed)
      screenplay = StoryboardPromptCompiler.compile!(screenplay)
      repair = AssetProfiler.repair_source_contract!(screenplay, project, assets, selection: nil)
      assets = repair["assets"]
      production_bible = ProductionBible.compile(
        screenplay: screenplay, assets: assets, selection: nil, original_prompt: project.prompt
      )
      screenplay = ContinuityPlanner.plan!(screenplay, production_bible)
      screenplay = ConsistencyEnforcer.apply!(
        screenplay, nil, assets, rich_prompt: true, production_bible: production_bible
      )
      ensure_script_consistency!(screenplay)

      client ||= HappyHorseClient.new unless project.dry_run?
      reference_errors = regenerate_stale_references!(
        assets, repair["changed_asset_ids"], project: project, client: client, ledger: ledger
      )
      raise "Canonical reference repair failed: #{reference_errors.join('; ')}" if reference_errors.any?
      if repair["changed_asset_ids"].any?
        production_bible = ProductionBible.compile(
          screenplay: screenplay, assets: assets, selection: nil, original_prompt: project.prompt
        )
        screenplay = ContinuityPlanner.plan!(screenplay, production_bible)
        screenplay = ConsistencyEnforcer.apply!(
          screenplay, nil, assets, rich_prompt: true, production_bible: production_bible
        )
        ensure_script_consistency!(screenplay)
      end

      wanted = Array(shot_ids).map(&:to_s)
      targets = all_shots(screenplay).select { |shot| wanted.include?(shot["id"].to_s) }
      skipped = targets.select { |shot| respect_locks && locked?(shot) }.map { |shot| shot["id"].to_s }
      targets.reject! { |shot| respect_locks && locked?(shot) }
      raise "No regenerable storyboard frames were selected" if targets.empty?

      plate_result = ContinuityPlatePlanner.generate!(
        screenplay: screenplay,
        production_bible: production_bible,
        client: client,
        ledger: ledger,
        dry_run: project.dry_run?,
        shot_ids: targets.map { |shot| shot["id"] }
      )
      if plate_result["errors"].any?
        raise "Required continuity plate generation failed: #{plate_result['errors'].join('; ')}"
      end
      CanonicalMediaStore.materialize_screenplay!(project.id, screenplay) unless project.dry_run?

      generation_errors = generate_frames!(targets, project: project, client: client, ledger: ledger)
      unless project.dry_run?
        CanonicalMediaStore.materialize_screenplay!(project.id, screenplay)
        targets.each do |shot|
          unless StableMedia.local_available?(shot["stable_image_url"])
            generation_errors << "Shot #{shot['id']} could not be stored durably"
          end
        end
      end
      visual = evaluate(evaluator, screenplay, production_bible, targets, ledger, qwen_config)

      failed_target_ids = Array(visual["failed_shot_ids"]).map(&:to_s) & targets.map { |shot| shot["id"].to_s }
      automatic_repair = project.direction.to_h["pipeline_mode"].to_s == "agentic"
      if automatic_repair && visual["status"] == "measured" && failed_target_ids.any?
        initial_visual = visual.deep_dup
        reports = Array(visual["shots"]).index_by { |row| row["shot_id"].to_s }
        correction_targets = targets.select { |shot| failed_target_ids.include?(shot["id"].to_s) }
        correction_targets.each do |shot|
          report_row = reports[shot["id"].to_s].to_h
          issues = (Array(report_row["issues"]) + Array(report_row["hard_failures"])).uniq.join("; ")
          shot["visual_prompt"] = "#{shot['visual_prompt']} | AUTOMATIC VISUAL CORRECTION: #{issues}; SCALE LOCK IS NON-NEGOTIABLE; match same-class peers on the same depth plane"
        end
        generation_errors.concat(generate_frames!(correction_targets, project: project, client: client, ledger: ledger))
        CanonicalMediaStore.materialize_screenplay!(project.id, screenplay) unless project.dry_run?
        recheck = evaluate(evaluator, screenplay, production_bible, correction_targets, ledger, qwen_config)
        visual = merge_visual_results(initial_visual, recheck)
      end

      report = ConsistencyEvaluator.evaluate(
        screenplay: screenplay,
        production_bible: production_bible,
        assets: assets,
        strict_references: !project.dry_run?
      )
      report["visual_metrics"] = visual
      attach_visual_gate!(report, visual, require_visual: !project.dry_run?)

      ledger.delete(:allow_token_overrun)
      ledger[:overrun_authorized] = allow_token_overrun == true

      manifest["assets"] = assets
      manifest["screenplay"] = screenplay
      manifest["production_bible"] = production_bible
      manifest["consistency_report"] = report
      manifest["edit_decision_list"] = screenplay["edit_decision_list"]
      manifest["budget_ledger"] = ledger
      manifest.delete("video_consistency_report")
      manifest.delete("video_jobs")
      manifest.delete("pending_video_review")

      {
        "manifest" => manifest,
        "images" => targets.map { |shot| { "shot_id" => shot["id"], "image_url" => shot["image_url"] } },
        "asset_images" => %w[characters props locations].flat_map do |type|
          Array(assets[type]).map { |asset| { "asset_type" => type, "asset_id" => asset["id"], "image_url" => asset["image_url"] } }
        end,
        "changed_asset_ids" => repair["changed_asset_ids"],
        "skipped_shot_ids" => skipped,
        "errors" => generation_errors,
        "consistency_report" => report,
        "ledger" => ledger,
        "generated_at" => Time.current.to_f
      }
    end

    def ensure_project_visual_budget!(project:, shot_count:, allow_token_overrun: false)
      return if allow_token_overrun == true

      batches = [(shot_count.to_f / VisualConsistencyEvaluator::SHOTS_PER_BATCH).ceil, 1].max
      required = (MIN_VISUAL_QA_TOKENS * batches) + shot_count.to_i * VISUAL_QA_TOKENS_PER_SHOT
      remaining = (project.tokens_remaining.presence || project.token_budget).to_i
      return if remaining >= required

      raise QwenRouter::BudgetExceeded,
        "Insufficient token budget for regeneration plus mandatory visual QA: " \
        "#{remaining} remaining, at least #{required} required for #{shot_count.to_i} shot(s). " \
        "No image credits were spent."
    end

    private

    def ensure_script_consistency!(screenplay)
      report = screenplay["script_consistency_report"] || {}
      return if report["ready"] != false

      details = Array(report["issues"]).select { |item| item["severity"] == "critical" }
        .map { |item| "#{item['shot_id']}: #{item['message']}" }.join("; ")
      raise "Script consistency gate rejected regeneration before image generation: #{details}"
    end

    def regenerate_stale_references!(assets, changed_ids, project:, client:, ledger:)
      errors = []
      Array(assets["characters"]).each_with_index do |character, index|
        next unless changed_ids.include?(character["id"].presence || "char_#{index + 1}")

        if project.dry_run?
          url = "/placeholders/character_#{index + 1}.png"
        else
          result = client.submit_with_retries(prompt: AssetProfiler.character_reference_prompt(character), mode: :t2i)
          charge!(ledger)
          unless result.succeeded? && remote_url?(result.image_url)
            errors << "#{character['name']} did not return a canonical image"
            next
          end
          url = result.image_url
        end
        character["image_url"] = url
        character["reference_images"] = [url]
        if !project.dry_run? && character["scale_calibration_prompt"].present?
          calibration = client.submit_with_retries(
            prompt: character["scale_calibration_prompt"],
            mode: :t2i,
            reference_image_urls: [url]
          )
          charge!(ledger)
          if calibration.succeeded? && remote_url?(calibration.image_url)
            character["scale_calibration_image_url"] = calibration.image_url
            character["qa_reference_images"] = [calibration.image_url]
          else
            errors << "#{character['name']} did not return a scale calibration image"
          end
        end
      rescue StandardError => e
        charge!(ledger) unless project.dry_run?
        errors << "#{character['name']}: #{e.message}"
      end
      CanonicalMediaStore.materialize_assets!(project.id, assets) unless project.dry_run?
      errors
    end

    def generate_frames!(shots, project:, client:, ledger:)
      errors = []
      shots.each do |shot|
        if project.dry_run?
          shot["image_url"] = "/placeholders/shot_#{shot['id'].to_s.tr('.', '_')}.png"
          next
        end

        previous_url = shot["image_url"]
        result = client.submit_with_retries(
          prompt: shot["visual_prompt"], mode: :t2i,
          reference_image_urls: shot.dig("continuity", "reference_image_urls")
        )
        charge!(ledger)
        if result.succeeded? && remote_url?(result.image_url) && result.image_url != previous_url
          shot["image_url"] = result.image_url
        else
          errors << "Shot #{shot['id']} did not return a new image"
        end
      rescue StandardError => e
        charge!(ledger) unless project.dry_run?
        errors << "Shot #{shot['id']}: #{e.message}"
      end
      errors
    end

    def evaluate(evaluator, screenplay, production_bible, targets, ledger, config)
      evaluator.evaluate(
        screenplay: screenplay,
        production_bible: production_bible,
        shot_ids: targets.map { |shot| shot["id"] },
        ledger: ledger,
        config: config
      )
    end

    # Keep the first measured audit if the smaller corrective recheck cannot
    # run (for example because the project budget was consumed by generation).
    # A real failure must stay FAILED, never regress to the ambiguous PENDING
    # state merely because a second audit was unavailable.
    def merge_visual_results(initial, recheck)
      unless recheck["status"] == "measured"
        return initial.merge(
          "recheck_status" => "not_measured",
          "recheck_reason" => recheck["reason"].to_s
        )
      end

      replacements = Array(recheck["shots"]).index_by { |row| row["shot_id"].to_s }
      rows = Array(initial["shots"]).map do |row|
        replacements[row["shot_id"].to_s] || row
      end
      new_rows = replacements.values.reject do |row|
        rows.any? { |existing| existing["shot_id"].to_s == row["shot_id"].to_s }
      end
      rows.concat(new_rows)
      initial.merge(
        "shots" => rows,
        "shots_evaluated" => rows.size,
        "failed_shot_ids" => rows.reject { |row| row["pass"] }.map { |row| row["shot_id"] },
        "average_score" => rows.any? ? (rows.sum { |row| row["overall_score"].to_i }.to_f / rows.size).round(1) : nil,
        "summary" => recheck["summary"].presence || initial["summary"],
        "recheck_status" => "measured"
      )
    end

    def attach_visual_gate!(report, visual, require_visual:)
      failed = Array(visual["failed_shot_ids"])
      if require_visual && visual["status"] != "measured"
        add_critical!(report, nil, "visual_audit_unavailable", "Visual consistency could not be measured after regeneration")
      elsif require_visual && failed.any?
        failed.each do |shot_id|
          add_critical!(report, shot_id, "visual_consistency_failed", "Regenerated keyframe still violates identity, prop or scale constraints")
        end
      end
      report["ready_for_render"] = report["critical_count"].zero?
      report["structural_score"] = [[report["structural_score"].to_i - failed.size * 10, 0].max, 100].min
    end

    def add_critical!(report, shot_id, code, message)
      report["critical_count"] += 1
      report["issues"] << { "severity" => "critical", "shot_id" => shot_id, "code" => code, "message" => message }
    end

    def all_shots(screenplay)
      Array(screenplay["scenes"]).flat_map { |scene| Array(scene["shots"]) }
    end

    def locked?(shot)
      ActiveRecord::Type::Boolean.new.cast(shot["locked"])
    end

    def charge!(ledger)
      ledger[:video_credits_used] = ledger[:video_credits_used].to_i + 1
    end

    def remote_url?(value)
      value.to_s.start_with?("http://", "https://")
    end
  end
end
