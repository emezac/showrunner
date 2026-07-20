# frozen_string_literal: true

require "showrunner"

class ShowrunnerAgent < ApplicationAgent
  def self.production_status_for(pipeline_mode:, consistency_report:)
    return "awaiting_storyboard_approval" unless pipeline_mode.to_s == "agentic"
    return "awaiting_storyboard_approval" if ConsistencyOverridePolicy.overrideable?(consistency_report.to_h)

    consistency_report.to_h["ready_for_render"] == false ? "failed" : "rendering"
  end

  def call(project)
    project_id = project.id
    project = PreproductionCheckpoint.active!(project_id)
    unless project.status == "planning"
      Rails.logger.info(
        "[ShowrunnerAgent ID:#{project_id}] Skipping stale or duplicate planning job; " \
        "current status is #{project.status.inspect}"
      )
      return true
    end

    agent_log(event: "started", payload: { project_id: project_id })
    checkpoint_stage = PreproductionCheckpoint.stage_for(project)
    cancellation_check = -> { PreproductionCheckpoint.active!(project_id) }

    # Helper to broadcast live progress to the user interface
    log_progress = ->(msg) {
      cancellation_check.call
      Rails.logger.info("[ShowrunnerAgent ID:#{project_id}] #{msg}")
      ActionCable.server.broadcast(
        "project_#{project_id}",
        { type: "progress", message: msg }.merge(pipeline_event_for(msg))
      )
    }

    log_progress.call("ShowrunnerAgent started. Analyzing creative inputs...")

    # 1. Búsqueda inteligente e in-memory cache de inspiración en memoria semántica
    manifest_data = (project.manifest || {}).with_indifferent_access
    inspiration_context = manifest_data["inspiration_context"]

    # El proceso de uso de memoria (dreaming) solo debe ejecutarse para prompts básicos o vagos.
    # Si el prompt es estructurado o es rico (más de 800 caracteres), no debe buscar inspiración.
    is_rich = Screenwriter.parse_scenes_from_prompt(project.prompt).present? || project.prompt.to_s.strip.length > 800

    if is_rich
      log_progress.call("Rich or structured prompt detected. Skipping semantic-memory inspiration search...")
      inspiration_context = ""
    elsif inspiration_context.blank?
      log_progress.call("Searching semantic memory for inspiration...")
      if project.dry_run || Agentkit::Memory.count == 0
        inspiration_context = "No similar previous stories were found."
      else
        similar_stories = recall!("story #{project.prompt}", k: 3)
        inspiration_context = if similar_stories.any?
                                "Inspiration from previous stories:\n" + similar_stories.map(&:content).join("\n---\n")
        else
                                "No similar previous stories were found."
        end
      end
    end

    log_progress.call("Inspiration resolved. Configuring dramatic archetypes...")

    # 2. Configurar el motor de showrunner
    # Obtenemos los overrides del proyecto
    mode_policy = ProductionModePolicy.resolve(input: project.direction || {}, prompt: project.prompt)
    overrides = mode_policy["direction"]
    project.update!(direction: overrides) if ProductionModePolicy.automatic?(overrides) && project.direction.to_h != overrides
    pipeline_mode = overrides["pipeline_mode"].presence || "agentic"
    automatic_mode = pipeline_mode == "agentic"

    # Creamos la configuración para Showrunner
    config = {
      prompt:          project.prompt,
      output:          "", # No output file for plan phase
      target_duration: project.duration,
      resolution:      project.resolution,
      token_budget:    project.token_budget,
      video_model:     :happyhorse_1_1,
      quality:         "high",
      dry_run:         project.dry_run,
      seed:            project.seed,
      force_story:     overrides["force_story"],
      force_domain:    overrides["force_domain"],
      adaptation_mode: overrides["adaptation_mode"] || "faithful"
    }

    engine = ShowrunnerEngine.new(config: config)
    forecast_overrun_authorized = ProductionTokenPredictor.authorization_valid_for_project?(project)
    if forecast_overrun_authorized
      engine.token_ledger[:allow_token_overrun] = true
      engine.token_ledger[:token_budget] = project.token_budget.to_i
    end
    if checkpoint_stage.present? && manifest_data["story"].present?
      engine.restore_selection!(manifest_data["story"])
      log_progress.call("Resuming the preserved pre-production contract from #{checkpoint_stage.humanize}...")
    else
      engine.resolve_story!
    end

    log_progress.call("Narrative domain assigned: #{engine.selection.domain.to_s.titleize}")

    max_scenes = overrides["max_scenes"]&.to_i

    # 3. Enriquecer el system prompt con inspiración de la memoria semántica
    # Escribimos el guion a través del Screenwriter
    # Para integrarse con QwenRouter, le pasamos el token ledger de agentkit o el local
    selection_tokens = engine.token_ledger[:tokens_used].to_i
    available_before_selection = project.tokens_remaining.nil? ? project.token_budget.to_i : project.tokens_remaining.to_i
    ledger = {
      tokens_used:      project.tokens_used.to_i + selection_tokens,
      tokens_remaining: [ available_before_selection - selection_tokens, 0 ].max,
      token_budget:     project.token_budget.to_i,
      tokens_over_budget: [ project.tokens_used.to_i + selection_tokens - project.token_budget.to_i, 0 ].max,
      allow_token_overrun: forecast_overrun_authorized,
      video_credits_used: project.video_credits_used,
      calls:            (Array(manifest_data.dig("budget_ledger", "calls")) +
                         Array(engine.token_ledger[:calls])).dup
    }
    qwen_config = QwenRouter::Config.default.dup
    if project.dry_run
      qwen_config.read_timeout = 20
      qwen_config.max_retries = 1
    end

    # Ejecutamos la planificación (fase 1)
    # Story selection, screenplay writing, storyboard compression
    # Intentamos la generación online real con Qwen para todos los proyectos (incluso dry_run)
    if PreproductionCheckpoint.reached?(checkpoint_stage, "screenplay") && manifest_data["screenplay"].present?
      screenplay = manifest_data["screenplay"].deep_dup
      screenplay_quality = manifest_data["screenplay_quality_report"] ||
        ScreenplayEvaluator.evaluate(screenplay, target_duration: project.duration)
      log_progress.call("Reusing checkpointed screenplay; no new screenplay tokens will be spent...")
    else
      begin
        log_progress.call("Calling Qwen Cloud to draft screenplay...")

      director_map = {
        "nolan" => "Christopher Nolan style (tense, tragic, cerebral, grand scale, complex pacing)",
        "villeneuve" => "Denis Villeneuve style (epic, atmospheric, sweeping vistas, deep focus, solemn pacing)",
        "kurosawa" => "Akira Kurosawa style (highly stylized, focus on honor and movement, high contrast)",
        "fincher" => "David Fincher style (dark, precise, low-key lighting, heavy shadows, clinical camera movement)"
      }
      camera_map = {
        "cinematic" => "Cinematic camera movement, professional framing, balanced composition, high production value",
        "handheld_shaky" => "Intense handheld camera, shaky cam, high energy, immersive physical movements",
        "slow_pans_fixed" => "Slow and fixed pans, smooth tripod movements, elegant compositions",
        "dutch_angles_extreme" => "Dutch angles and high tension framing, off-kilter compositions to build dread"
      }
      color_map = {
        "cinematic" => "Cinematic color grading, rich vibrant tones, realistic shadows, filmic contrast",
        "cyberpunk" => "Cool tone, neon-soaked cyberpunk color grading, high contrast blues and pinks",
        "warm" => "Warm tone, golden hour desert color grading, rich ambers and soft shadows",
        "noir" => "Monochrome, high-contrast film noir black and white color grading, dramatic chiascuro shadows",
        "kodak" => "Vintage, saturated analog Kodak film color grading, retro warmth, authentic grain",
        "apocalyptic" => "Apocalyptic sepia color grading, dusty, desolate earth tones, heavy atmosphere"
      }

      prompt_builder = project.prompt.dup
      prompt_builder += "\n\n[Cinematic Genre]: #{overrides['genre'].to_s.titleize}" if overrides["genre"].present?
      prompt_builder += "\n\n[Target Audience]: #{overrides['audience']}" if overrides["audience"].present?
      prompt_builder += "\n\n[Brain Dump / Unstructured Draft]: #{overrides['brain_dump']}" if overrides["brain_dump"].present?
      prompt_builder += "\n\n[Narrative Context]: #{inspiration_context}" if inspiration_context.present?
      prompt_builder += "\n\n[Director Style]: #{director_map[overrides['director_influence']]}" if director_map[overrides["director_influence"]]
      prompt_builder += "\n\n[Camera Direction]: #{camera_map[overrides['camera_style']]}" if camera_map[overrides["camera_style"]]
      prompt_builder += "\n\n[Color Palette & Grading]: #{color_map[overrides['color_grade']]}" if color_map[overrides["color_grade"]]

        sp, _r = Screenwriter.generate!(
          selection: engine.selection,
          prompt: prompt_builder,
          target_duration: project.duration,
          max_scenes: max_scenes,
          ledger: ledger,
          config: qwen_config,
          adaptation_mode: overrides["adaptation_mode"] || "faithful"
        )
        screenplay = sp
      rescue ActiveRecord::RecordNotFound
        raise
      rescue StandardError => e
        log_progress.call("Qwen screenplay generation could not satisfy the narrative contract: #{e.message}. Recovering with the source-locked local planner...")
        Rails.logger.warn(
          "[ShowrunnerAgent ID:#{project.id}] screenplay generation recovered with local planner: " \
          "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(15).join("\n")}"
        )
        # Fallback local sin red
        screenplay = Screenwriter.generate_offline(
          selection: engine.selection,
          prompt: project.prompt,
          target_duration: project.duration,
          max_scenes: max_scenes
        )
        screenplay["generation_recovery"] = {
          "status" => "recovered",
          "stage" => "screenplay",
          "strategy" => "source_locked_local_planner",
          "reason" => e.message
        }
      end

      log_progress.call("Screenplay received. Compiling scene intent, timing and edit decisions...")
      source_parse = Screenwriter.parse_scenes_from_prompt(project.prompt)
      screenplay["source_profiles"] ||= source_parse&.dig("source_profiles")
      screenplay = ScreenplayPlanner.upgrade!(
        screenplay,
        target_duration: project.duration,
        max_scenes: is_rich ? nil : max_scenes,
        seed: project.seed
      )
      screenplay, = Storyboarder.compress!(screenplay, ledger: ledger, config: qwen_config)
      screenplay_quality = ScreenplayEvaluator.evaluate(screenplay, target_duration: project.duration)
      unless screenplay_quality["ready_for_storyboard"]
        issue_summary = Array(screenplay_quality["issues"])
          .select { |issue| issue["severity"] == "critical" }
          .map { |issue| [ issue["code"], issue["scene_id"] || issue["shot_id"] ].compact.join("@") }
          .join(", ")
        log_progress.call("Online screenplay failed structural preflight (#{issue_summary}). Recovering locally without restarting production...")
        Rails.logger.warn(
          "[ShowrunnerAgent ID:#{project.id}] structural screenplay recovery: " \
          "#{screenplay_quality['issues'].inspect}"
        )
        screenplay = Screenwriter.generate_offline(
          selection: engine.selection,
          prompt: project.prompt,
          target_duration: project.duration,
          max_scenes: max_scenes
        )
        screenplay["source_profiles"] ||= source_parse&.dig("source_profiles")
        screenplay["generation_recovery"] = {
          "status" => "recovered",
          "stage" => "screenplay_preflight",
          "strategy" => "source_locked_local_planner",
          "issues" => Array(screenplay_quality["issues"])
        }
        screenplay = ScreenplayPlanner.upgrade!(
          screenplay,
          target_duration: project.duration,
          max_scenes: is_rich ? nil : max_scenes,
          seed: project.seed
        )
        screenplay, = Storyboarder.compress!(screenplay, ledger: ledger, config: qwen_config)
        screenplay_quality = ScreenplayEvaluator.evaluate(screenplay, target_duration: project.duration)
        unless screenplay_quality["ready_for_storyboard"]
          raise "Source-locked screenplay recovery failed: #{screenplay_quality['issues'].inspect}"
        end
      end

      project = PreproductionCheckpoint.persist!(
        project_id: project_id,
        stage: "screenplay",
        ledger: ledger,
        data: {
          "story" => engine.to_manifest["story"],
          "screenplay" => screenplay,
          "screenplay_quality_report" => screenplay_quality,
          "edit_decision_list" => screenplay["edit_decision_list"],
          "inspiration_context" => inspiration_context
        }
      )
      manifest_data = project.manifest.with_indifferent_access
      checkpoint_stage = "screenplay"
    end

    log_progress.call("Screenplay written. Initiating profiling for character & location assets...")
    if PreproductionCheckpoint.reached?(checkpoint_stage, "assets") && manifest_data["assets"].present?
      assets = manifest_data["assets"].deep_dup
      log_progress.call("Reusing checkpointed canonical assets; no new asset credits will be spent...")
    else
      assets = AssetProfiler.profile!(
        screenplay, project, ledger: ledger, config: qwen_config, selection: engine.selection,
        cancellation_check: cancellation_check
      )
      if assets["props"].blank? && !project.dry_run?
        assets = AssetProfiler.profile_missing_props!(
          screenplay, project, assets, ledger: ledger, config: qwen_config,
          cancellation_check: cancellation_check
        )
        assets["profiling_report"] = AssetFidelityEvaluator.evaluate(
          source_prompt: project.prompt,
          source_profiles: screenplay["source_profiles"],
          assets: assets
        ).merge("source_locked" => true)
      end
      unless assets.dig("profiling_report", "ready")
        raise "Asset fidelity gate rejected canonical reference generation"
      end
      unless project.dry_run?
        missing_references = %w[characters props locations].flat_map do |type|
          Array(assets[type]).reject { |asset| asset["image_url"].to_s.start_with?("http://", "https://") }
            .map { |asset| "#{type}:#{asset['name']}" }
        end
        if missing_references.any?
          raise "Canonical reference generation incomplete: #{missing_references.join(', ')}"
        end
        CanonicalMediaStore.materialize_assets!(project_id, assets)
        missing_durable_references = %w[characters props locations].flat_map do |type|
          Array(assets[type]).reject { |asset| StableMedia.local_available?(asset["stable_image_url"]) }
            .map { |asset| "#{type}:#{asset['name']}" }
        end
        if missing_durable_references.any?
          raise "Durable canonical reference persistence failed: #{missing_durable_references.join(', ')}"
        end
      end

      project = PreproductionCheckpoint.persist!(
        project_id: project_id,
        stage: "assets",
        ledger: ledger,
        data: { "screenplay" => screenplay, "assets" => assets }
      )
      manifest_data = project.manifest.with_indifferent_access
      checkpoint_stage = "assets"
    end

    log_progress.call("Assets profiled. Compiling production bible and physical continuity...")
    if PreproductionCheckpoint.reached?(checkpoint_stage, "storyboard") &&
        manifest_data["production_bible"].present?
      screenplay = manifest_data["screenplay"].deep_dup
      production_bible = manifest_data["production_bible"].deep_dup
      client = HappyHorseClient.new unless project.dry_run
      log_progress.call("Reusing checkpointed storyboard frames; no new image credits will be spent...")
    else
      production_bible = ProductionBible.compile(
        screenplay: screenplay,
        assets: assets,
        selection: engine.selection,
        original_prompt: project.prompt
      )
      screenplay = ContinuityPlanner.plan!(screenplay, production_bible)
      screenplay = ConsistencyEnforcer.apply!(
        screenplay,
        engine.selection,
        assets,
        rich_prompt: is_rich,
        production_bible: production_bible
      )
      script_consistency = screenplay["script_consistency_report"] || {}
      if script_consistency["ready"] == false
        conflicts = Array(script_consistency["issues"]).select { |item| item["severity"] == "critical" }
        raise "Script consistency gate rejected input: #{conflicts.map { |item| "#{item['shot_id']}: #{item['message']}" }.join('; ')}"
      end

      log_progress.call("Generating storyboard base frames via wan2.7-image-pro...")
      unless project.dry_run
        client = HappyHorseClient.new
        plate_result = ContinuityPlatePlanner.generate!(
          screenplay: screenplay,
          production_bible: production_bible,
          client: client,
          ledger: ledger,
          cancellation_check: cancellation_check
        )
        if plate_result["errors"].any?
          raise "Required continuity plate generation failed: #{plate_result['errors'].join('; ')}"
        end
        CanonicalMediaStore.materialize_screenplay!(project_id, screenplay)

        project = PreproductionCheckpoint.persist!(
          project_id: project_id,
          stage: "assets",
          ledger: ledger,
          data: { "screenplay" => screenplay, "assets" => assets, "production_bible" => production_bible }
        )
        screenplay["scenes"].each do |scene|
          scene["shots"].each do |shot|
            next if StableMedia.local_available?(shot["stable_image_url"])
            next if StableMedia.usable_remote?(shot["image_url"])

            attempted = false
            begin
              cancellation_check.call
              attempted = true
              job_result = client.submit_with_retries(
                prompt: shot["visual_prompt"],
                mode: :t2i,
                reference_image_urls: shot.dig("continuity", "reference_image_urls")
              )
              cancellation_check.call
              shot["image_url"] = job_result.image_url if job_result.succeeded?
              CanonicalMediaStore.materialize_screenplay!(project_id, screenplay) if job_result.succeeded?
            rescue ActiveRecord::RecordNotFound
              raise
            rescue StandardError => e
              Rails.logger.warn("Shot image generation failed: #{e.message}")
              shot["image_url"] = "/placeholders/shot_#{shot['id'].to_s.tr('.', '_')}.png"
            ensure
              ledger[:video_credits_used] = ledger[:video_credits_used].to_i + 1 if attempted
            end

            project = PreproductionCheckpoint.persist!(
              project_id: project_id,
              stage: "assets",
              ledger: ledger,
              data: { "screenplay" => screenplay, "assets" => assets, "production_bible" => production_bible }
            )
          end
        end
      else
        screenplay["scenes"].each do |scene|
          scene["shots"].each do |shot|
            shot["image_url"] = "/placeholders/shot_#{shot['id'].to_s.tr('.', '_')}.png"
          end
        end
      end

      project = PreproductionCheckpoint.persist!(
        project_id: project_id,
        stage: "storyboard",
        ledger: ledger,
        data: {
          "screenplay" => screenplay,
          "assets" => assets,
          "production_bible" => production_bible,
          "edit_decision_list" => screenplay["edit_decision_list"]
        }
      )
      manifest_data = project.manifest.with_indifferent_access
      checkpoint_stage = "storyboard"
    end
    engine.screenplay = screenplay

    if PreproductionCheckpoint.reached?(checkpoint_stage, "visual_qa") &&
        manifest_data["visual_consistency_report"].present?
      visual_consistency = manifest_data["visual_consistency_report"].deep_dup
      log_progress.call("Reusing checkpointed storyboard QA; no new vision tokens will be spent...")
    else
      visual_consistency = { "status" => "not_measured", "reason" => "dry run" }
      unless project.dry_run
        log_progress.call("Auditing storyboard identity, props and scale with Qwen Vision...")
        visual_consistency = VisualConsistencyEvaluator.evaluate(
          screenplay: screenplay,
          production_bible: production_bible,
          ledger: ledger,
          config: qwen_config,
          cancellation_check: cancellation_check
        )

        failed_ids = Array(visual_consistency["failed_shot_ids"])
        if failed_ids.any? && automatic_mode
          log_progress.call("Correcting #{failed_ids.size} inconsistent storyboard keyframe(s)...")
          repair_storyboard_keyframes!(
            screenplay, visual_consistency, client, ledger,
            cancellation_check: cancellation_check
          )
          CanonicalMediaStore.materialize_screenplay!(project_id, screenplay)
          visual_consistency = VisualConsistencyEvaluator.evaluate(
            screenplay: screenplay,
            production_bible: production_bible,
            ledger: ledger,
            config: qwen_config,
            cancellation_check: cancellation_check
          )
        end
      end

      project = PreproductionCheckpoint.persist!(
        project_id: project_id,
        stage: "visual_qa",
        ledger: ledger,
        data: {
          "screenplay" => screenplay,
          "assets" => assets,
          "production_bible" => production_bible,
          "visual_consistency_report" => visual_consistency
        }
      )
      manifest_data = project.manifest.with_indifferent_access
      checkpoint_stage = "visual_qa"
    end

    log_progress.call("Binding shots and character consistency...")

    # 4. Guardar datos en el manifest y en el proyecto
    # Guardamos los tokens consumidos
    ledger[:overrun_authorized] = forecast_overrun_authorized
    ledger.delete(:allow_token_overrun)
    project.tokens_used = ledger[:tokens_used]
    project.tokens_remaining = ledger[:tokens_remaining]
    project.video_credits_used = ledger[:video_credits_used] || 0

    # Preparamos el manifest completo (extendido con display/reasoning)
    manifest = engine.to_manifest.with_indifferent_access
    manifest["screenplay"] = screenplay
    manifest["assets"] = assets
    manifest["production_bible"] = production_bible
    consistency_report = ConsistencyEvaluator.evaluate(
      screenplay: screenplay,
      production_bible: production_bible,
      assets: assets,
      strict_references: !project.dry_run?
    )
    consistency_report["visual_metrics"] = visual_consistency
    if !project.dry_run? && visual_consistency["status"] != "measured"
      consistency_report["ready_for_render"] = false
      consistency_report["critical_count"] += 1
      consistency_report["issues"] << {
        "severity" => "critical", "shot_id" => nil,
        "code" => "visual_audit_unavailable",
        "message" => "Storyboard visual fidelity could not be measured"
      }
    elsif !project.dry_run? && Array(visual_consistency["failed_shot_ids"]).any?
      Array(visual_consistency["failed_shot_ids"]).each do |shot_id|
        consistency_report["ready_for_render"] = false
        consistency_report["critical_count"] += 1
        consistency_report["issues"] << {
          "severity" => "critical", "shot_id" => shot_id,
          "code" => "visual_consistency_failed",
          "message" => "Storyboard keyframe failed identity, prop or relative-scale QA after automatic repair"
        }
      end
    end
    manifest["consistency_report"] = consistency_report
    manifest["screenplay_quality_report"] = screenplay_quality
    manifest["edit_decision_list"] = screenplay["edit_decision_list"]
    manifest["budget_ledger"] = ledger
    manifest["inspiration_context"] = inspiration_context
    manifest["preproduction_checkpoint"] = {
      "version" => PreproductionCheckpoint::VERSION,
      "stage" => "completed",
      "input_digest" => PreproductionCheckpoint.input_digest(project),
      "saved_at" => Time.current.iso8601
    }

    # Generamos la ficha cinematográfica usando el DisplayComposer
    display_info = DisplayComposer.compose(manifest, engine.selection)
    manifest["story"]["display"] = display_info[:display]
    manifest["reasoning"] = display_info[:reasoning]
    manifest["quality_meter"] = display_info[:quality_meter]
    manifest["coherence_metrics"] = display_info[:coherence_metrics]

    next_status = self.class.production_status_for(
      pipeline_mode: pipeline_mode,
      consistency_report: consistency_report
    )
    if next_status == "rendering" && forecast_overrun_authorized
      manifest["render_token_overrun"] = {
        "authorized" => true,
        "scope" => "next_video_render",
        "source" => "production_token_forecast",
        "forecast_digest" => project.direction.to_h["production_token_overrun_digest"],
        "authorized_at" => project.direction.to_h["production_token_overrun_approved_at"]
      }
    end

    log_progress.call(
      if next_status == "rendering"
        "Consistency gates passed. Starting autonomous video production..."
      elsif next_status == "failed"
        "Autonomous preflight paused: consistency gate requires attention."
      else
        "Production slate calculated. Preparing human review..."
      end
    )

    project = PreproductionCheckpoint.active!(project_id)
    project.manifest = manifest
    project.title = screenplay["title"] || display_info[:display][:title]
    project.status = next_status
    project.save!

    # 5. Guardar en memoria semántica de AgentKit (solo en producción/online)
    unless project.dry_run
      cancellation_check.call
      observation_text = "Drama titled '#{project.title}' generated with prompt '#{project.prompt}' under domain '#{engine.selection.domain}'."
      memorize!(
        observation_text,
        tags:       [ "showrunner_plan", "project_#{project.id}", engine.selection.domain.to_s ],
        type:       "observation",
        confidence: 0.9
      )
    end

    # Human-in-the-loop suggestions belong only to Review & Control mode.
    if pipeline_mode == "control"
      cancellation_check.call
      suggest!(
        type:        "storyboard_review",
        title:       "Approve Storyboard: #{project.title}",
        description: "The screenplay and storyboard for '#{project.title}' under domain '#{engine.selection.domain}' are ready for review.",
        priority:    "high",
        suggestable: project,
        payload:     {
          "project_id" => project.id,
          "scenes_count" => screenplay["scenes"]&.size || 0,
          "shots_count" => screenplay["scenes"]&.flat_map { |s| s["shots"] }&.size || 0,
          "estimated_tokens" => ledger[:tokens_used]
        }
      )
    end

    log_progress.call("Pre-production phase completed successfully.")

    # Notificamos el cambio de estado a la UI
    ActionCable.server.broadcast(
      "project_#{project.id}",
      { type: "status", status: next_status, stage: next_status == "rendering" ? "video_production" : "review" }
    )

    if next_status == "rendering"
      cancellation_check.call
      ProduceDramaJob.perform_later(project.id)
    end

    agent_log(event: "completed", payload: { project_id: project.id })
    true
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.info(
      "[ShowrunnerAgent ID:#{project_id || project&.id}] Project was deleted; " \
      "cancelling pre-production without retry: #{e.message}"
    )
    true
  end

  private

  def pipeline_event_for(message)
    text = message.to_s.downcase
    case text
    when /render|video production/
      { stage: "video_production", progress: 72, state: "running" }
    when /consisten|audit|vision|preflight|binding/
      { stage: "consistency_qa", progress: 58, state: "running" }
    when /storyboard|keyframe|asset|reference/
      { stage: "storyboard", progress: 44, state: "running" }
    when /screenplay|narrative|story|archetype|prompt/
      { stage: "narrative", progress: 24, state: "running" }
    else
      { stage: "planning", progress: 10, state: "running" }
    end
  end

  def repair_storyboard_keyframes!(screenplay, visual_report, client, ledger, cancellation_check: nil)
    reports = Array(visual_report["shots"]).index_by { |row| row["shot_id"].to_s }
    failed_ids = Array(visual_report["failed_shot_ids"]).map(&:to_s)

    Array(screenplay["scenes"]).each do |scene|
      Array(scene["shots"]).each do |shot|
        next unless failed_ids.include?(shot["id"].to_s)
        next if ActiveRecord::Type::Boolean.new.cast(shot["locked"])
        cancellation_check&.call

        report_row = reports[shot["id"].to_s].to_h
        issues = (Array(report_row["issues"]) + Array(report_row["hard_failures"])).uniq.join("; ")
        correction_prompt = "#{shot['visual_prompt']} | CONTINUITY CORRECTION: #{issues}; obey every CANON, SCALE and PHYSICS lock exactly"
        result = client.submit_with_retries(
          prompt: correction_prompt,
          mode: :t2i,
          reference_image_urls: shot.dig("continuity", "reference_image_urls")
        )
        cancellation_check&.call
        next unless result.succeeded?

        shot["image_url"] = result.image_url
        ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1
      rescue ActiveRecord::RecordNotFound
        raise
      rescue StandardError => e
        Rails.logger.warn("Storyboard consistency repair failed for #{shot['id']}: #{e.message}")
      end
    end
  end
end
