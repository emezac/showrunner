# frozen_string_literal: true

require "./lib/showrunner"
require "net/http"
require "uri"
require "digest"

class ProduceDramaJob < ApplicationJob
  RUNTIME_VERSION = "2026-07-20.durable-canonical-media-v4"

  queue_as :default

  def perform(project_id)
    capabilities = {
      audio_narration_resolution: AudioDirector.respond_to?(:resolve_narration),
      persisted_story_selection: ShowrunnerEngine.instance_methods.include?(:restore_selection!)
    }
    Rails.logger.info(
      "[ProduceDramaJob] Runtime #{RUNTIME_VERSION} requested project #{project_id}; " \
      "capabilities=#{capabilities.to_json}"
    )
    project = claim_render!(project_id)
    return unless project

    broadcast_progress(project_id, "Starting rendering...")
    broadcast_progress(project_id, "Securing durable local copies of approved visual references...")
    manifest = CanonicalMediaStore.materialize_manifest!(project).with_indifferent_access
    # Keep this authorization only in job memory. It is one-shot and must not
    # be written back by any of the intermediate manifest checkpoints below.
    legacy_clip_recovery_authorization = manifest.delete("legacy_clip_recovery")
    render_overrun = ActiveRecord::Type::Boolean.new.cast(manifest.dig("render_token_overrun", "authorized")) &&
      manifest.dig("render_token_overrun", "scope") == "next_video_render"
    # Consume both one-shot authorizations when the job starts. Keep the local
    # copy for this run, but never leave a reusable bypass in persisted state.
    persisted_manifest = manifest.deep_dup
    persisted_manifest.delete("render_token_overrun")
    persisted_manifest.delete("visual_qa_override")
    persisted_direction = project.direction.to_h
    if render_overrun && manifest.dig("render_token_overrun", "source") == "production_token_forecast"
      persisted_direction["production_token_overrun_consumed_at"] = Time.current.iso8601
    end
    project.update!(manifest: persisted_manifest, direction: persisted_direction)

    # Aseguramos el directorio público para los cortos
    dramas_dir = Rails.root.join("public", "dramas")
    FileUtils.mkdir_p(dramas_dir)
    output_file = File.join(dramas_dir, "drama_#{project.id}.mp4")

    # Resolve Automatic defaults once, and reject unresolved Full Control
    # choices before any provider credits are spent.
    mode_policy = ProductionModePolicy.resolve(input: project.direction || {}, prompt: project.prompt)
    if mode_policy["errors"].any?
      fail_render!(
        project,
        manifest: manifest,
        message: "Full Control configuration is incomplete: #{mode_policy['errors'].join('; ')}",
        outcome: "invalid_full_control_configuration"
      )
      return
    end
    overrides = mode_policy["direction"]
    project.update!(direction: overrides) if project.direction.to_h != overrides
    automatic_mode = ProductionModePolicy.automatic?(overrides)
    config = {
      prompt:          project.prompt,
      output:          output_file,
      target_duration: project.duration,
      resolution:      project.resolution,
      token_budget:    project.tokens_remaining.presence || project.token_budget,
      video_model:     :happyhorse_1_1,
      quality:         "high",
      dry_run:         project.dry_run,
      seed:            project.seed,
      force_story:     overrides["force_story"],
      force_domain:    overrides["force_domain"],
      adaptation_mode: overrides["adaptation_mode"] || "faithful",
      keep_workdir:    true
    }

    # Callback para emitir progreso mediante ActionCable
    progress_cb = ->(msg) do
      broadcast_progress(project_id, msg)
    end

    engine = ShowrunnerEngine.new(
      config: config,
      progress_callback: progress_cb,
      happyhorse_logger: Rails.logger
    )
    if render_overrun
      engine.token_ledger[:allow_token_overrun] = true
      engine.token_ledger[:token_budget] = project.token_budget.to_i
    end
    
    # Asignamos el screenplay de la base de datos
    # Esto asegura que cualquier modificación hecha por el usuario en el storyboard
    # sea respetada en la generación del video.
    screenplay = manifest["screenplay"]
    assets = manifest["assets"]
    if manifest["story"].present?
      engine.restore_selection!(manifest["story"])
    else
      engine.resolve_story!
    end

    # Upgrade legacy/user-edited storyboards before rendering. This preserves
    # explicit camera and story choices while rebuilding exact timing and EDL.
    screenplay = ScreenplayPlanner.upgrade!(
      screenplay,
      target_duration: project.duration,
      max_scenes: nil,
      seed: project.seed
    )
    screenplay = StoryboardPromptCompiler.compile!(screenplay)

    narration = AudioDirector.resolve_narration(screenplay)
    if overrides["voice_style"].to_s != "none" && narration["text"].blank?
      fail_render!(
        project,
        manifest: manifest,
        message: "Narration was selected, but the approved screenplay has no spoken text or narrative scene actions to voice",
        outcome: "audio_contract_incomplete",
        ledger: engine.token_ledger
      )
      return
    end

    # Migrate legacy manifests that stored a calibration sheet as the primary
    # character image. The technical plate remains QA-only and a clean
    # narrative reference is regenerated below.
    source_repair = AssetProfiler.repair_source_contract!(screenplay, project, assets || {}, selection: engine.selection)
    assets = source_repair["assets"]
    if source_repair["changed_asset_ids"].any?
      manifest["assets"] = assets
      project.update!(manifest: manifest)
    end

    assets_reprofiled = source_repair["changed_asset_ids"].any?
    legacy_fidelity = AssetFidelityEvaluator.evaluate(
      source_prompt: project.prompt,
      source_profiles: screenplay["source_profiles"],
      assets: assets || {}
    )
    unless legacy_fidelity["ready"]
      broadcast_progress(project_id, "Legacy assets failed source fidelity; rebuilding canonical references...")
      assets = AssetProfiler.profile!(
        screenplay,
        project,
        ledger: engine.token_ledger,
        config: QwenRouter::Config.default,
        selection: engine.selection
      )
      unless assets.dig("profiling_report", "ready")
        manifest["consistency_report"] = {
          "ready_for_render" => false,
          "critical_count" => legacy_fidelity["issues"].size,
          "issues" => legacy_fidelity["issues"],
          "asset_fidelity" => legacy_fidelity
        }
        fail_render!(
          project,
          manifest: manifest,
          message: "Canonical assets could not satisfy the approved source contract",
          outcome: "blocked_before_video_synthesis_by_asset_fidelity",
          ledger: engine.token_ledger
        )
        return
      end
      manifest["assets"] = assets
      assets_reprofiled = true
    end

    if !project.dry_run? && Array(assets&.dig("props")).empty?
      broadcast_progress(project_id, "Upgrading legacy manifest with canonical recurring props...")
      assets = AssetProfiler.profile_missing_props!(
        screenplay,
        project,
        assets || {},
        ledger: engine.token_ledger,
        config: QwenRouter::Config.default
      )
      manifest["assets"] = assets
      manifest["consistency_report"] ||= {}
      manifest["consistency_report"]["visual_metrics"] = {
        "status" => "not_measured",
        "reason" => "legacy manifest was upgraded with canonical props"
      }
      project.manifest = manifest
      project.save!
    end

    # Ensure every canonical reference needed by multi-reference keyframes or
    # per-character R2V is still reachable. DashScope OSS URLs expire.
    unless project.dry_run?
      broadcast_progress(project_id, "Verifying canonical character, prop and location references...")
      canonical_references_changed = ensure_canonical_references!(project, manifest)
      assets_reprofiled = assets_reprofiled || canonical_references_changed
      assets = manifest["assets"]
    end


    # Recompile the generic production contract because the user may have
    # edited the storyboard or an asset after planning.
    production_bible = ProductionBible.compile(
      screenplay: screenplay,
      assets: assets,
      selection: engine.selection,
      original_prompt: project.prompt
    )
    screenplay = ContinuityPlanner.plan!(screenplay, production_bible)

    # Bind canonical entities, object invariants and physical constraints to
    # every video prompt. The selected render strategy decides whether the
    # approved shot keyframe or the primary character reference is the anchor.
    is_rich = Screenwriter.parse_scenes_from_prompt(project.prompt).present? || project.prompt.to_s.strip.length > 800
    screenplay = ConsistencyEnforcer.apply!(
      screenplay,
      engine.selection,
      assets,
      for_video: true,
      rich_prompt: is_rich,
      production_bible: production_bible
    )
    script_consistency = screenplay["script_consistency_report"] || {}
    if script_consistency["ready"] == false
      manifest["screenplay"] = screenplay
      manifest["consistency_report"] = ConsistencyEvaluator.evaluate(
        screenplay: screenplay, production_bible: production_bible, assets: assets,
        strict_references: !project.dry_run?
      )
      fail_render!(
        project,
        manifest: manifest,
        message: "Script consistency gate rejected contradictory input before video rendering",
        outcome: "blocked_before_video_synthesis_by_script_consistency",
        ledger: engine.token_ledger
      )
      return
    end
    screenplay_quality = ScreenplayEvaluator.evaluate(screenplay, target_duration: project.duration)
    unless screenplay_quality["ready_for_storyboard"]
      manifest["screenplay_quality_report"] = screenplay_quality
      manifest["screenplay"] = screenplay
      fail_render!(
        project,
        manifest: manifest,
        message: "Screenplay preflight rejected the edit plan",
        outcome: "blocked_before_video_synthesis_by_screenplay_preflight",
        ledger: engine.token_ledger
      )
      return
    end
    unless project.dry_run?
      broadcast_progress(project_id, "Verifying canonical keyframes for multi-entity shots...")
      ensure_storyboard_keyframes!(project, screenplay)
    end
    if assets_reprofiled && !project.dry_run?
      broadcast_progress(project_id, "Auditing rebuilt storyboard references against the source...")
      manifest["consistency_report"] ||= {}
      manifest["consistency_report"]["visual_metrics"] = VisualConsistencyEvaluator.evaluate(
        screenplay: screenplay,
        production_bible: production_bible,
        ledger: engine.token_ledger,
        config: QwenRouter::Config.default
      )
    end
    planned_visual_metrics = manifest.dig("consistency_report", "visual_metrics")
    consistency_report = ConsistencyEvaluator.evaluate(
      screenplay: screenplay,
      production_bible: production_bible,
      assets: assets,
      strict_references: !project.dry_run?
    )
    if planned_visual_metrics.present? && planned_visual_metrics["status"] == "measured"
      consistency_report["visual_metrics"] = planned_visual_metrics
      failed_visual_shots = Array(planned_visual_metrics["failed_shot_ids"])
      if failed_visual_shots.any?
        consistency_report["ready_for_render"] = false
        consistency_report["critical_count"] += failed_visual_shots.size
        failed_visual_shots.each do |shot_id|
          consistency_report["issues"] << {
            "severity" => "critical",
            "shot_id" => shot_id,
            "code" => "visual_consistency_failed",
            "message" => "Storyboard keyframe failed visual continuity after automatic repair"
          }
        end
      end
    elsif !project.dry_run?
      consistency_report["ready_for_render"] = false
      consistency_report["critical_count"] += 1
      consistency_report["issues"] << {
        "severity" => "critical", "shot_id" => nil,
        "code" => "visual_audit_required",
        "message" => "A measured storyboard visual audit is required before paid video rendering"
      }
    end
    visual_risk_authorized = ConsistencyOverridePolicy.valid?(manifest: manifest, screenplay: screenplay)
    ConsistencyOverridePolicy.apply!(
      report: consistency_report,
      manifest: manifest,
      screenplay: screenplay
    )
    manifest.delete("render_token_overrun")
    manifest.delete("visual_qa_override")
    manifest["production_bible"] = production_bible
    manifest["consistency_report"] = consistency_report
    manifest["screenplay_quality_report"] = screenplay_quality
    manifest["edit_decision_list"] = screenplay["edit_decision_list"]
    manifest["screenplay"] = screenplay
    project.manifest = manifest
    project.save!
    if visual_risk_authorized
      broadcast_progress(project_id, "Producer visual-risk authorization verified for storyboard and final video QA")
    end
    unless consistency_report["ready_for_render"]
      message = "Consistency preflight rejected the storyboard: #{consistency_report['critical_count']} critical issue(s)"
      fail_render!(
        project,
        manifest: manifest,
        message: message,
        outcome: "blocked_before_video_synthesis_by_storyboard_visual_qa",
        ledger: engine.token_ledger
      )
      return
    end
    engine.screenplay = screenplay

    begin
      audio_plan = AudioDirector.prepare!(
        screenplay: screenplay,
        direction: overrides,
        output_dir: Rails.root.join("tmp", "showrunner_audio"),
        target_duration: project.duration
      )
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.info("[ProduceDramaJob] Project #{project_id} was deleted; cancelling render without retry: #{e.message}")
      return
    rescue StandardError => e
      fail_render!(
        project,
        manifest: manifest,
        message: "Audio preflight failed before video rendering: #{e.message}",
        outcome: "blocked_before_video_synthesis_by_audio_preflight",
        ledger: engine.token_ledger
      )
      return
    end
    manifest["audio_plan"] = audio_plan.except("voice_track").merge(
      "mode" => automatic_mode ? "automatic" : "full_control"
    )
    project.update!(manifest: manifest)

    engine.apply_overrides(
      soundtrack_style: audio_plan["soundtrack_style"],
      voice_track: audio_plan["voice_track"],
      audio_required: audio_plan["audio_required"]
    )

    start_time = Time.current
    video_quality_evaluator = lambda do |screenplay:, shot_paths:, production_bible:|
      VideoConsistencyEvaluator.evaluate(
        screenplay: screenplay,
        shot_paths: shot_paths,
        production_bible: production_bible,
        ledger: engine.token_ledger,
        config: QwenRouter::Config.default
      )
    end

    begin
      recovery_manifest = manifest.merge(
        "legacy_clip_recovery" => legacy_clip_recovery_authorization
      )
      legacy_task_recovery_allowed = ConsistencyOverridePolicy.legacy_clip_recovery_valid?(
        manifest: recovery_manifest
      )
      # Ejecutamos el renderizador y el montaje pasando los assets aprobados
      # para que VideoSynth pueda usar R2V con la imagen de referencia del personaje.
      engine.render!(
        verbose: true,
        workdir: Rails.root.join("tmp", "showrunner_clip_cache", "project_#{project.id}"),
        assets: assets,
        production_bible: production_bible,
        quality_evaluator: video_quality_evaluator,
        prior_video_quality_report: manifest["video_consistency_report"],
        prior_video_jobs: manifest["video_jobs"],
        allow_legacy_task_recovery: legacy_task_recovery_allowed,
        allow_visual_qa_override: visual_risk_authorized,
        auto_repair: automatic_mode
      )

      end_time = Time.current
      total_duration = end_time - start_time

      # Registramos los tiempos empíricos
      RenderTiming.create!(
        project: project,
        n_shots: screenplay["scenes"]&.flat_map { |s| s["shots"] }&.size || 0,
        resolution: project.resolution,
        total_seconds: total_duration
      )

      # Actualizamos presupuesto y estado final
      ledger = engine.token_ledger
      project.tokens_used += ledger[:tokens_used]
      project.tokens_remaining = [(project.tokens_remaining || project.token_budget) - ledger[:tokens_used], 0].max
      rendered_shots = engine.video_jobs.count { |job| job[:task_id].present? }
      project.video_credits_used = if project.dry_run?
                                     0
                                   else
                                     (project.video_credits_used || 0) + rendered_shots + ledger[:video_credits_used].to_i
                                   end

      # Guardamos el manifest final, restaurando el screenplay original para no perder las descripciones ricas
      old_manifest = (project.manifest || {}).with_indifferent_access
      manifest = engine.to_manifest.with_indifferent_access
      manifest["screenplay"] = old_manifest["screenplay"]
      manifest["assets"] = old_manifest["assets"] if old_manifest["assets"].present?
      manifest["production_bible"] = old_manifest["production_bible"] if old_manifest["production_bible"].present?
      manifest["consistency_report"] = old_manifest["consistency_report"] if old_manifest["consistency_report"].present?
      manifest["inspiration_context"] = old_manifest["inspiration_context"] if old_manifest["inspiration_context"].present?
      manifest["audio_plan"] = old_manifest["audio_plan"] if old_manifest["audio_plan"].present?
      manifest["render_runtime"] = old_manifest["render_runtime"].to_h.merge(
        "state" => "completed",
        "outcome" => "completed",
        "finished_at" => Time.current.iso8601
      )

      # Re-mapeamos display
      display_info = DisplayComposer.compose(manifest, engine.selection)
      manifest["story"]["display"] = display_info[:display]
      manifest["reasoning"] = display_info[:reasoning]
      manifest["quality_meter"] = display_info[:quality_meter]
      manifest["coherence_metrics"] = display_info[:coherence_metrics]
      manifest.delete("render_token_overrun")
      manifest.delete("visual_qa_override")
      manifest.delete("pending_video_review")

      project.manifest = manifest
      project.final_video_url = "/dramas/drama_#{project.id}.mp4"
      project.status = "completed"
      project.save!

      broadcast_status(project_id, "completed", project.final_video_url)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.info("[ProduceDramaJob] Project #{project_id} was deleted; cancelling render without retry: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[ProduceDramaJob] Error rendering project #{project_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      
      failed_manifest = (project.manifest || {}).with_indifferent_access
      failed_manifest.delete("render_token_overrun")
      failed_manifest.delete("visual_qa_override")
      failed_manifest["video_consistency_report"] = engine.video_consistency_report
      failed_manifest["video_jobs"] = engine.video_jobs
      failed_manifest["render_runtime"] = failed_manifest["render_runtime"].to_h.merge(
        "state" => "failed",
        "outcome" => (e.message.start_with?("Video consistency gate") ? "final_video_qa_rejected" : "video_render_failed"),
        "finished_at" => Time.current.iso8601,
        "error" => e.message.to_s[0, 500]
      )
      recoverable_video_gate_failure = e.message.start_with?("Video consistency gate")
      if recoverable_video_gate_failure && File.file?(output_file) && File.size(output_file).positive?
        failed_manifest["pending_video_review"] = {
          "available" => true,
          "url" => "/dramas/drama_#{project.id}.mp4",
          "video_sha256" => Digest::SHA256.file(output_file).hexdigest,
          "render_contract_digest" => ConsistencyOverridePolicy.render_contract_digest(failed_manifest),
          "failed_shot_ids" => Array(engine.video_consistency_report["failed_shot_ids"]),
          "created_at" => Time.current.iso8601
        }
      else
        failed_manifest.delete("pending_video_review")
      end
      failed_credits = engine.video_jobs.count { |job| job[:task_id].present? } + engine.token_ledger[:video_credits_used].to_i
      project.update!(
        status: "failed",
        manifest: failed_manifest,
        tokens_used: project.tokens_used + engine.token_ledger[:tokens_used].to_i,
        tokens_remaining: [(project.tokens_remaining || project.token_budget).to_i - engine.token_ledger[:tokens_used].to_i, 0].max,
        video_credits_used: project.video_credits_used.to_i + failed_credits
      )
      broadcast_progress(project_id, "Rendering failed: #{e.message}")
      broadcast_status(project_id, "failed")
    ensure
      FileUtils.rm_f(audio_plan&.dig("voice_track"))
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.info("[ProduceDramaJob] Project #{project_id} was deleted; cancelling job without retry: #{e.message}")
  ensure
    finalize_render_runtime!(project_id)
  end

  private

  def fail_render!(project, manifest:, message:, outcome:, ledger: nil)
    failed_manifest = (manifest || project.manifest || {}).with_indifferent_access
    failed_manifest.delete("render_token_overrun")
    failed_manifest.delete("visual_qa_override")
    failed_manifest["render_runtime"] = failed_manifest["render_runtime"].to_h.merge(
      "state" => "failed",
      "outcome" => outcome,
      "finished_at" => Time.current.iso8601,
      "error" => message.to_s[0, 500]
    )
    usage = ledger.to_h.with_indifferent_access
    tokens = usage["tokens_used"].to_i
    credits = usage["video_credits_used"].to_i
    failed_manifest["last_render_ledger"] = usage.except("allow_token_overrun") if usage.present?
    project.update!(
      status: "failed",
      manifest: failed_manifest,
      tokens_used: project.tokens_used.to_i + tokens,
      tokens_remaining: [project.tokens_remaining.to_i - tokens, 0].max,
      video_credits_used: project.video_credits_used.to_i + credits
    )
    broadcast_progress(project.id, message)
    broadcast_status(project.id, "failed")
  end

  def claim_render!(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    claimed = false
    project.with_lock do
      manifest = (project.manifest || {}).with_indifferent_access
      runtime = manifest["render_runtime"].to_h
      other_job_running = runtime["state"] == "running" &&
        runtime["job_id"].present? && runtime["job_id"] != job_id &&
        runtime_fresh?(runtime["started_at"])

      if project.status != "rendering" || other_job_running
        Rails.logger.info(
          "[ProduceDramaJob] Skipping stale or duplicate render for project #{project_id}; " \
          "status=#{project.status.inspect}, active_job_id=#{runtime['job_id'].inspect}"
        )
      else
        manifest["render_runtime"] = {
          "version" => RUNTIME_VERSION,
          "job_id" => job_id,
          "state" => "running",
          "started_at" => Time.current.iso8601
        }
        project.update!(manifest: manifest)
        claimed = true
      end
    end

    claimed ? project : nil
  end

  def finalize_render_runtime!(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    project.with_lock do
      manifest = (project.manifest || {}).with_indifferent_access
      runtime = manifest["render_runtime"].to_h
      if runtime["job_id"] == job_id && runtime["state"] == "running" && project.status != "rendering"
        runtime["state"] = project.status == "completed" ? "completed" : "failed"
        runtime["finished_at"] ||= Time.current.iso8601
        manifest["render_runtime"] = runtime
        project.update!(manifest: manifest)
      end
      Rails.logger.info(
        "[ProduceDramaJob] Outcome project=#{project_id} status=#{project.status.inspect} " \
        "video=#{project.final_video_url.presence || 'none'}"
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[ProduceDramaJob] Could not persist final runtime outcome for #{project_id}: #{e.message}")
  end

  def runtime_fresh?(started_at)
    Time.zone.parse(started_at.to_s) > 6.hours.ago
  rescue ArgumentError, TypeError
    false
  end

  def ensure_canonical_references!(project, manifest)
    client = HappyHorseClient.new
    changed = false

    %w[characters props locations].each do |asset_type|
      Array(manifest.dig("assets", asset_type)).each do |asset|
        ensure_project_active!(project.id)
        url = asset["image_url"].to_s
        if StableMedia.local_available?(asset["stable_image_url"]) &&
            !(asset_type == "characters" && AssetProfiler.technical_reference_prompt?(asset["visual_prompt"]))
          next
        end
        if url.start_with?("http") && url_reachable?(url) &&
            !(asset_type == "characters" && AssetProfiler.technical_reference_prompt?(asset["visual_prompt"]))
          asset["reference_images"] = ([url] + Array(asset["reference_images"])).uniq.first(2) if asset_type == "characters"
          next
        end

        fallback = case asset_type
                   when "characters"
                     "Canonical full-body reference of #{asset['name']}, #{asset['physical_description']}, neutral pose, plain background"
                   when "props"
                     "Neutral canonical product reference of #{asset['name']}, #{asset['description']}, exact material, color and scale"
                   else
                     "Canonical empty environment reference of #{asset['name']}, #{asset['description']}, fixed spatial layout"
                   end
        prompt = asset_type == "characters" ? AssetProfiler.character_reference_prompt(asset) : asset["visual_prompt"].presence || fallback
        result = client.submit_with_retries(prompt: prompt, mode: :t2i)
        next unless result.succeeded? && result.image_url.to_s.start_with?("http")

        asset["image_url"] = result.image_url
        if asset_type == "characters"
          asset["reference_images"] = ([result.image_url] + Array(asset["reference_images"]).reject { |candidate| candidate == url }).uniq.first(2)
        end
        project.video_credits_used = (project.video_credits_used || 0) + 1
        changed = true
      rescue ActiveRecord::RecordNotFound
        raise
      rescue StandardError => e
        Rails.logger.warn("[ProduceDramaJob] canonical #{asset_type} reference failed for #{asset['id']}: #{e.message}")
      end
    end

    project.manifest = manifest
    CanonicalMediaStore.materialize_assets!(project.id, manifest["assets"] || {})
    project.save! if changed
    changed
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.warn("[ProduceDramaJob] ensure_canonical_references! failed: #{e.message}")
    false
  end

  # Multi-entity shots rely on an approved full-composition keyframe. Rebuild
  # only missing/expired keyframes; single-character R2V shots keep using the
  # canonical character reference.
  def ensure_storyboard_keyframes!(project, screenplay)
    client = HappyHorseClient.new
    changed = false

    Array(screenplay["scenes"]).each do |scene|
      Array(scene["shots"]).each do |shot|
        ensure_project_active!(project.id)
        next unless shot.dig("continuity", "render_strategy") == "keyframe_i2v"
        next if StableMedia.local_available?(shot["stable_image_url"])
        next if shot["image_url"].to_s.start_with?("http") && url_reachable?(shot["image_url"])

        result = client.submit_with_retries(
          prompt: shot["visual_prompt"],
          mode: :t2i,
          reference_image_urls: shot.dig("continuity", "reference_image_urls")
        )
        next unless result.succeeded? && result.image_url.to_s.start_with?("http")

        shot["image_url"] = result.image_url
        project.video_credits_used = (project.video_credits_used || 0) + 1
        changed = true
      rescue ActiveRecord::RecordNotFound
        raise
      rescue StandardError => e
        Rails.logger.warn("[ProduceDramaJob] keyframe #{shot['id']} regeneration failed: #{e.message}")
      end
    end

    CanonicalMediaStore.materialize_screenplay!(project.id, screenplay)
    project.save! if changed
    changed
  end

  # Comprobación gratuita (sin créditos) de que la URL sigue viva.
  # GET con Range bytes=0-0: las URLs OSS están firmadas para GET (un HEAD
  # daría 403 aunque la URL sea válida) y así solo se transfiere 1 byte.
  def url_reachable?(url)
    uri = URI.parse(url)
    req = Net::HTTP::Get.new(uri.request_uri)
    req["Range"] = "bytes=0-0"
    res = Net::HTTP.start(uri.host, uri.port,
                          use_ssl: uri.scheme == "https",
                          open_timeout: 5, read_timeout: 5) { |http| http.request(req) }
    res.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end

  def broadcast_progress(project_id, message)
    ensure_project_active!(project_id)
    event = pipeline_event_for(message)
    ActionCable.server.broadcast(
      "project_#{project_id}",
      { type: "progress", message: message }.merge(event)
    )
  end

  def ensure_project_active!(project_id)
    Project.find(project_id)
  end

  def broadcast_status(project_id, status, video_url = nil)
    ActionCable.server.broadcast(
      "project_#{project_id}",
      { type: "status", status: status, video_url: video_url }
    )
  end

  def pipeline_event_for(message)
    text = message.to_s.downcase
    case text
    when /edit|final|complete/
      { stage: "edit_delivery", progress: 94, state: "running" }
    when /audit|consisten|verif|preflight|repair/
      { stage: "final_qa", progress: 84, state: "running" }
    when /render|video|clip|happyhorse/
      { stage: "video_production", progress: 72, state: "running" }
    else
      { stage: "video_production", progress: 64, state: "running" }
    end
  end
end
