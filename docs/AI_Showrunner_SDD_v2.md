# SOFTWARE DESIGN DOCUMENT v2.0
## AI Showrunner — "De generador de video a Showrunner autónomo"
**Qwen Cloud Global AI Hackathon — Track 2: AI Showrunner**
Versión 2.0 — Reemplaza v1.0. Autor: Enrique. Ruby 3.x / Rails 8 / DashScope-Qwen / HappyHorse.

---

## 0. Qué cambia respecto a la v1.0 y por qué

La v1.0 (`AI_Showrunner_SDD.txt`) describía una arquitectura Ruby DSL, manifest, motor Python (`showrunner_engine.py`), DashScope. El código que realmente existe hoy (`showrunner.rb`, `qwen_router.rb`, `happy_horse_client.rb`) ya no tiene ese motor Python: el pipeline completo corre en Ruby puro, con modulos reales (StoryEngine, EntityBible, NarrativeBeats, Screenwriter, Storyboarder, ConsistencyEnforcer, VideoSynth, Editor) que ya resuelven varios de los "fixes brutales" de continuidad narrativa y visual que la v1 solo prometia en abstracto.

Esta v2.0 tiene dos objetivos:

1. Documentar la arquitectura real tal como existe en el codigo (ground truth = los .rb), no la arquitectura aspiracional de la v1.
2. Especificar de forma ultragranular como incorporar las 17 mejoras de `mejoras.md`, cuyo hilo conductor es un solo diagnostico: "el usuario obtiene un video; deberia obtener una produccion, y deberia ver al Showrunner razonar, no solo esperar."

El backend de generacion (Qwen para texto, HappyHorse para video) no cambia. Lo que cambia es (a) el manifest se extiende con nuevos campos observables/editables, (b) el pipeline se divide en checkpoints pausables en vez de correr de punta a punta sin supervision, y (c) aparece una capa Rails/Hotwire que hace visible cada uno de esos campos.

---

## 1. Resumen ejecutivo

AI Showrunner recibe un prompt de una frase y entrega un corto dramatico completo (guion, storyboard, shots renderizados, montaje), con cero intervencion humana obligatoria, pero con intervencion humana opcional en 6 puntos de control: story DNA, storyboard, camara/direccion/color/musica/voz, timeline, regeneracion parcial, y variantes finales. El motor narrativo oculto (StoryEngine, transmutacion de "genes" de historias base sobre dominios destino) permanece como la ventaja de Innovacion; la novedad de producto de esta v2 es que ese motor se hace parcialmente visible y pilotable sin revelar su mecanismo interno (nunca se muestra "myth compiler", "DNA" como termino interno, ni el catalogo crudo; se muestra su resultado con lenguaje de produccion cinematografica).

Todo el pipeline sigue corriendo 100% en Ruby, sin subproceso Python, sin llamadas a LLMs fuera de Qwen (QwenRouter, unico adaptador), y sin llamadas a video fuera de HappyHorse/DashScope (HappyHorseClient, unico adaptador, y es el archivo de prueba de despliegue en Alibaba Cloud, SDD v1 §9.1).

---

## 2. Alineacion con el hackathon (sin cambios respecto a v1)

- Track 2 — AI Showrunner. Deadline: 9 jul 2026, 15:00 CST.
- Checklist de entrega: repo publico con licencia OSS visible, archivo de prueba de despliegue Alibaba Cloud (`happy_horse_client.rb`), diagrama de arquitectura, demo <= 3 min sin musica con copyright de terceros, descripcion de funcionalidad, track identificado.
- Mapeo de criterios de jueces:

| Criterio | Peso | Como lo cubre v2 |
|---|---|---|
| Innovacion y creatividad IA | 30% | Motor narrativo oculto (StoryEngine + EntityBible + NarrativeBeats), ahora parcialmente expuesto como "razonamiento del Showrunner", mayor percepcion de agencia sin revelar el mecanismo. |
| Profundidad tecnica | 30% | Pipeline Ruby end-to-end real (no aspiracional), con fixes de continuidad (ConsistencyEnforcer), ritmo de montaje dinamico por beat narrativo (NarrativeBeats), fallback determinista sin red (dry_run). |
| Valor del problema | 25% | La capa de control (storyboard antes de render, regeneracion parcial, variantes) generaliza a cualquier pipeline de video corto, reduce el "sunk cost" de gastar creditos en un resultado no deseado. |
| Presentacion y documentacion | 15% | Este SDD + budget ledger visible en UI en tiempo real + panel de "por que esta historia" como pieza demostrable en el video de 3 min. |

---

## 3. Arquitectura real (ground truth = codigo)

```
Rails 8 App (UI operador + API)
ShowrunnerController -> Showrunner.produce(prompt) { DSL block }
  -> ShowrunnerEngine (Ruby, en-proceso o via ActiveJob/Sidekiq)
       -> BuildResult#manifest (JSON, ver Seccion 5)

ShowrunnerEngine#run!(workdir) ejecuta TODO en Ruby, sin subproceso:

  StoryEngine        (oculto, seeded, sin red)
  Screenwriter        (QwenRouter, 1 call batch para todas las escenas)
  Storyboarder        (QwenRouter, 1 call batch de compresion de prompts)
  ConsistencyEnforcer (Ruby puro, NO llama LLM; aplica Entity Bible literal a cada shot)
  VideoSynth          (HappyHorseClient via DashScope async+poll, submit_batch paralelo)
  Editor              (ffmpeg: xfade, grade unificado, audio ducking)

  -> output.mp4 + output.mp4.ledger.json
```

Diferencias clave vs. v1 que deben quedar explicitas en el diagrama de entrega:

- No existe `showrunner_engine.py`. Todo el pipeline vive en `ShowrunnerEngine#run!` (Ruby).
- `NarrativeBeats` impone una curva emocional obligatoria (mystery -> curiosity -> escalation -> danger -> climax -> revelation -> aftermath) en codigo, no confiando en que el LLM la produzca espontaneamente, y prioriza que beats sobreviven si hay menos escenas que beats (nunca se sacrifica climax ni revelation).
- `EntityBible` fija deterministicamente (a partir del seed) el aspecto del protagonista y de la carga, y `ConsistencyEnforcer` los reinyecta literalmente en cada visual_prompt, despues de la compresion de Storyboarder. Este es el paso que la v1 solo mencionaba como aspiracion ("ontological separation") y que en v2 es una garantia mecanica, no una sugerencia al modelo.
- El modo `dry_run: true` corre el pipeline completo sin red (ni Qwen ni HappyHorse), usando `Screenwriter.generate_offline` y `VideoSynth.fallback_still!`. Esto permite ensayar la demo de 3 minutos sin quemar presupuesto, y es tambien la base tecnica del Storyboard Preview de la mejora #2 (ver Seccion 6.2).

---

## 4. Product Framing — "Vender el Showrunner" (mejora #17)

Decision de producto transversal a todo lo demas: la superficie del producto deja de llamarse "generador de video" y pasa a mostrarse como un pipeline de produccion con 8 pasos visibles en tiempo real:

```
[x] Historia planeada
[x] Personajes creados
[x] Guion escrito
[x] Plan de camara generado
[>] Renderizando Escena 2 de 4
[ ] Renderizando Escena 3
[ ] Renderizando Escena 4
[ ] Editando
[ ] Finalizando
```

Mapeo tecnico -> UI (granular):

| Paso UI | Evento de codigo que lo dispara |
|---|---|
| "Historia planeada" | `ShowrunnerEngine#resolve_story!` completa (o `StoryEngine.classify_tone!` retorna) |
| "Personajes creados" | `EntityBible.build` retorna `[protagonist_bible, cargo_bible]` |
| "Guion escrito" | `Screenwriter.generate!` (o `.generate_offline` en dry_run) retorna `screenplay` |
| "Plan de camara generado" | `NarrativeBeats.assign` + `camera_for` aplicados en `Screenwriter.normalize_screenplay` |
| "Renderizando Escena N" | Callback de `VideoSynth.run!` / `client.submit_batch` por cada shot resuelto (streaming via ActionCable, no polling del navegador) |
| "Editando" | Entrada a `Editor.assemble!` |
| "Finalizando" | `write_ledger_sidecar!` + upload a OSS |

Esto requiere que `ShowrunnerEngine#run!` emita eventos (nuevo: un `progress_callback:` opcional, invocado en cada `log(verbose, msg)` existente) en vez de solo `puts` a stdout. Cambio minimo y no invasivo: envolver `log` para ademas hacer `ActionCable.server.broadcast("project_#{id}", ...)` cuando se ejecuta dentro de Rails.

---

## 5. Manifest v2 — Schema extendido

El manifest actual (`showrunner_preview.html`) tiene: `request`, `story`, `scene_overrides`, `screenplay`, `video_jobs`, `edit`, `budget_ledger`. v2 anade cinco bloques nuevos, todos opcionales/con default, para no romper el `to_manifest` existente:

```json
{
  "version": "2.0",
  "request": { "...": "sin cambios respecto a v1" },

  "story": {
    "...": "sin cambios en las claves internas (base_story_id, domain, preserved_genes, tone, protagonist_bible, cargo_bible)",
    "display": {
      "title": "The Soul Cargo",
      "genre_label": "Dark Fantasy",
      "emotional_beat_summary": "Curiosidad -> Horror -> Sacrificio",
      "quality_score": 8.9,
      "characters": ["Contrabandista", "La entidad"],
      "scene_titles": ["Descubrimiento", "Apertura", "Revelacion", "Decision"]
    }
  },

  "direction": {
    "director_influence": null,
    "camera_style": null,
    "color_grade": null,
    "music_style": null,
    "voice_style": null
  },

  "reasoning": {
    "detected_signals": ["hidden mystery", "emotional reveal", "sacrifice ending"],
    "chosen_structure": ["Discovery", "Suspense", "Supernatural reveal", "Emotional ending"]
  },

  "quality_meter": {
    "drama": 0.0, "action": 0.0, "visual_coherence": 0.0, "ending": 0.0
  },

  "coherence_metrics": {
    "narrative_coherence": null, "visual_consistency": null, "character_consistency": null
  },

  "scene_overrides": { "...": "sin cambios (max_scenes, shot_duration, voice_track, music_track)" },
  "screenplay": { "...": "sin cambios en forma; cada shot admite ahora un flag locked: true/false para regeneracion parcial" },
  "video_jobs": { "...": "sin cambios; cada entry admite variant_of: null|shot_id para variantes A/B/C" },
  "edit": { "...": "sin cambios" },
  "budget_ledger": { "...": "sin cambios" }
}
```

Regla de diseno (hereda del principio "ontological separation" de la v1 §4.1): el bloque `reasoning.detected_signals` y `chosen_structure` nunca deben usar vocabulario interno (myth_compiler, dna, gene, archetype_id, base_story_id crudo). Se traduce con un diccionario de labels (`StoryCatalog::DISPLAY_LABELS`, nuevo) antes de serializar hacia el bloque display/reasoning. Esto preserva el riesgo mitigado en v1 §12 ("judges perceive the story engine as a fixed template if the trick is noticed") ahora que se expone mas superficie.

---

## 6. Especificacion ultragranular de las 17 mejoras

Cada mejora se especifica como: Que ve el usuario -> De donde sale el dato -> Que componente Rails/Ruby lo produce -> Que trabajo nuevo requiere.

### 6.1 — Identidad cinematografica del resultado (mejora #1)

- UI: tarjeta de "ficha de produccion" (titulo, duracion, genero, beat emocional, score, personajes, escenas) reemplazando el video crudo como primer elemento mostrado.
- Fuente de datos: `story.display` (nuevo bloque, Seccion 5). `title` = `screenplay["title"]`. `genre_label` = mapeo de `domain` + `tone` via diccionario (ej. `dark_fantasy` si `domain: post_apocalyptic` + `tone: epic` + genes con `sacrifice`) — tabla de mapeo determinista, no LLM, para no gastar tokens en algo puramente cosmetico.
- Componente: nuevo `Showrunner::DisplayComposer` (Ruby, puro, sin red) que recibe el manifest completo y produce `display` + `reasoning` a partir de datos que YA existen en el manifest (no requiere nuevas llamadas a Qwen).
- Trabajo nuevo: tabla de mapeo domain x tone x genes -> genre_label; funcion quality_score (ver 6.5, reutiliza quality_meter).

### 6.2 — Storyboard antes del render (mejora #2) — la de mayor impacto en costo percibido

- UI: grid de 4 tarjetas (una por escena o shot representativo), cada una con: encuadre (camera), locacion derivada de visual_prompt, iluminacion derivada del beat. Botones "Render this" / "Regenerate Scene N".
- Fuente de datos: `screenplay["scenes"][i]["shots"]`, YA existe completo despues de `Screenwriter.generate!` + `Storyboarder.compress!` + `ConsistencyEnforcer.apply!`, y antes de `VideoSynth.run!`.
- Cambio de pipeline (el unico cambio estructural real de esta SDD): `ShowrunnerEngine#run!` se parte en dos fases invocables por separado:
  - `ShowrunnerEngine#plan!` -> ejecuta hasta `ConsistencyEnforcer.apply!` inclusive, persiste `screenplay` y retorna sin tocar VideoSynth/Editor. Costo: solo tokens de Qwen (texto), cero creditos de HappyHorse.
  - `ShowrunnerEngine#render!(from: :video_synth)` -> recibe el screenplay (posiblemente editado por el usuario) y continua desde `VideoSynth.run!`.
- Rails: `Project#status` gana un nuevo valor `awaiting_storyboard_approval` entre `planning` y `rendering`.
- Regenerate Scene N: vuelve a invocar Screenwriter solo para esa escena (nueva firma `Screenwriter.regenerate_scene!(screenplay:, scene_id:, selection:, ledger:, config:)` que reemplaza `scene["shots"]` de esa escena unicamente, reaplicando ConsistencyEnforcer solo a esos shots), evita re-generar las 4 escenas por el precio de 1.
- Storyboard visual real (opcional, fuera del MVP del hackathon): si se quiere mostrar un frame real y no solo texto, generar 1 first-frame por shot via capacidad de imagen de Qwen antes de HappyHorse (contemplado en Stage 4 de v1, hoy no implementado en showrunner.rb). Para el demo de 3 min, es mas barato y rapido mostrar el storyboard textual/iconografico (encuadre + locacion + luz) que generar frames reales.

### 6.3 — Timeline editable (mejora #3)

- UI: bloques 0-5s / 5-9s / 9-13s / 13-20s con etiqueta de escena, editables (drag para ajustar duracion).
- Fuente de datos: derivado de `screenplay["scenes"][i]["shots"][j]["duration"]` acumulado, no hay dato nuevo, es una vista calculada.
- Edicion real de duracion: cambiar shot["duration"] en el manifest ANTES de VideoSynth.run! es gratis (solo cambia el parametro duration enviado a HappyHorse). Cambiar duracion DESPUES del render implica volver a generar ese shot (HappyHorse no soporta trim server-side) — la UI debe dejar claro que editar el timeline solo es "gratis" en fase de storyboard, y cuesta 1 credito de regeneracion si el shot ya fue renderizado.
- Componente: vista pura en el frontend (Stimulus), sin nuevo endpoint mas alla de `PATCH /projects/:id/shots/:shot_id { duration: N }`, valido solo mientras `status == awaiting_storyboard_approval`.

### 6.4 — Genes visibles / "Story DNA" (mejora #4)

- UI: lista de genes con checkboxes (Sacrifice, Loyalty, Betrayal, Revenge), anadibles/removibles por el usuario sin revelar que provienen de un catalogo de "historias base" (regla de v1 §4.1: nunca mostrar el mecanismo).
- Fuente de datos: `story.preserved_genes` (ya existe, viene de `StoryCatalog::BASE_STORIES[...][:genes]`).
- Edicion por el usuario: si anade/quita un gen, debe re-inyectarse como restriccion explicita en el system prompt de `Screenwriter.generate!` (la linea "Genes narrativos a preservar: ..." ya existe en el user prompt; solo hay que hacerla mutable).
- Trabajo nuevo: `Screenwriter.generate!` debe aceptar `genes_override:` opcional que sobreescriba `selection.base_story[:genes]` en el interpolado del prompt, sin tocar StoryCatalog (el catalogo interno sigue siendo de solo lectura, el override vive en scene_overrides, igual que max_scenes/shot_duration hoy).
- Vocabulario: el label de cada gen (loyalty_test -> "Loyalty", power_struggle -> "Power Struggle", sacrifice -> "Sacrifice") sale de una tabla GENE_DISPLAY_LABELS nueva, nunca se muestra el snake_case interno.

### 6.5 — Quality meter (mejora #5)

- UI: 4 barras (Drama, Action, Visual coherence, Ending), 0-10 o 0-100%.
- Como se calcula sin gastar tokens extra (importante para el budget, v1 §10):
  - visual_coherence: derivable deterministicamente en Ruby a partir de cuantos shots conservan literalmente protagonist_bible/cargo_bible tras ConsistencyEnforcer.apply! (deberia ser 100% siempre por diseno, es mas prueba de que el enforcer funciono que metrica creativa).
  - drama/action/ending: requieren senal semantica que no es gratis en Ruby. Opcion A (barata): heuristica de palabras clave sobre scene["action"]/dialogue (conteo de verbos de alta intensidad, presencia de beats danger/climax con dialogo no vacio). Opcion B (mas fiel, cuesta tokens): 1 llamada Qwen adicional, batch, stage: :quality_score, <=100 tokens de salida, ejecutada en paralelo a Storyboarder.compress! para no anadir latencia serial.
  - Recomendacion para el demo: Opcion A (heuristica Ruby, cero tokens), cumple el objetivo de "dar confianza visual" sin comprometer el presupuesto de tokens que es criterio de juzgamiento explicito.
- Componente: `Showrunner::QualityMeter.score(screenplay)`, modulo Ruby puro, nuevo.

### 6.6 — Director Mode (mejora #6)

- UI: checkboxes de influencias (Denis Villeneuve, Guillermo del Toro, David Fincher, Hayao Miyazaki, Christopher Nolan) bajo el label generico "Cinematic Language" (no "copiar estilo").
- Fuente de datos -> prompt: cada influencia mapea a un fragmento de prompt para Screenwriter.generate! y Storyboarder.compress!, no a nombres propios literales en el prompt final de video.
  - Ej.: "Villeneuve" -> iluminacion atmosferica, espacio negativo, vistas amplias, paleta desaturada; ritmo lento y deliberado.
  - "Fincher" -> alto contraste, tonos verdosos-frios, encuadre simetrico preciso; ritmo ajustado y controlado.
- Componente: tabla estatica DIRECTOR_INFLUENCE_PROFILES (Ruby hash, nuevo), inyectada en direction.director_influence -> concatenada al system prompt de Storyboarder.compress! (que ya controla iluminacion/intensidad por beat, se combina con esa regla existente, no la reemplaza).
- Nota de producto: el nombre del director SI puede mostrarse en la UI (es una etiqueta de checkbox, eleccion editorial del usuario) pero nunca se envia tal cual al modelo de video como si fuera una cita o imitacion directa de una obra con copyright, se traduce siempre a lenguaje tecnico antes de tocar visual_prompt.

### 6.7 — Estilo de camara (mejora #7)

- UI: radio buttons (Static, Handheld, Slow Dolly, Drone, Cinematic).
- Fuente de datos: hoy NarrativeBeats.camera_for(beat, previous_camera, rng) decide la camara por beat, con un pool fijo por beat y garantia de no-repeticion consecutiva. La mejora #7 pide que el usuario module ese pool.
- Trabajo nuevo: NarrativeBeats::CAMERA_BY_BEAT pasa de constante fija a metodo camera_pool_for(beat, style_override: nil), si style_override esta presente (ej. :handheld), se filtra el pool del beat a solo opciones compatibles (o se fija a una unica opcion si el usuario pide "Static" en todo el corto). Mantiene la regla de "nunca repetir camara anterior si hay alternativa" solo cuando el pool filtrado tiene mas de una opcion.

### 6.8 — Color grading / Look (mejora #8)

- UI: chips seleccionables (Noir, Cyberpunk, Kodak Film, Warm, Cold, Apocalyptic).
- Fuente de datos -> ejecucion real: hoy Editor::UNIFIED_GRADE es una constante ffmpeg fija. La mejora la convierte en una tabla COLOR_GRADE_PRESETS (Ruby hash con un filtro ffmpeg distinto por look), seleccionada por direction.color_grade y usada por Editor.xfade_chain/grade_single_clip en vez de la constante fija.
- Costo: cero tokens, es un cambio puramente en el filtro ffmpeg. Impacto de UX alto por costo de implementacion bajo, buena relacion esfuerzo/impacto para el demo.

### 6.9 — Musica (mejora #9)

- UI: chips (Epic, Ambient, Suspense, Piano, Electronic, None).
- Estado actual: edit.music_track siempre null; Editor.build_audio_filter ya soporta mezclar musica con ducking si se provee un music_track (path a archivo).
- Trabajo nuevo (obligatorio, no cosmetico): biblioteca de pistas libres de derechos (condicion explicita del hackathon: sin musica con copyright de terceros en el demo). 6 pistas cortas (una por chip), pre-licenciadas, alojadas en OSS. El chip solo selecciona music_track = presets[selection]; no hay generacion de musica por IA en el alcance de este hackathon.
- Riesgo: si el demo usa musica de stock sin licencia clara, viola el requisito del track; la biblioteca debe documentarse con fuente/licencia en el repo (assets/music/LICENSES.md).

### 6.10 — Voz / narrador (mejora #10)

- UI: chips (Male, Female, None, AI Character Voices).
- Estado actual: edit.voice_track ya soportado por Editor.build_audio_filter (ducking musica bajo voz). No existe hoy generacion de voz en el pipeline.
- Trabajo nuevo: integrar un TTS (fuera del alcance de Qwen/HappyHorse). Si DashScope/Qwen Cloud ofrece un servicio de voz, usarlo para mantener "todo en Alibaba Cloud"; si no, dejar "AI Character Voices" fuera del MVP y mostrar el chip como "Proximamente" para no prometer algo no construido.
- Prioridad: baja para el demo de 3 min, es la mejora con menor relacion impacto/esfuerzo si implica integrar un proveedor de voz nuevo bajo deadline.

### 6.11 — Presupuesto visible (mejora #11)

- UI: barra de creditos, costo estimado en tokens, tiempo de render estimado.
- Fuente de datos: budget_ledger ya existe completo (tokens_used, tokens_remaining, video_credits_used, calls), es el bloque menos nuevo de toda la mejora, solo falta exponerlo en UI.
- Tiempo de render estimado: dato nuevo, derivable de forma barata: n_shots x tiempo_medio_observado_por_shot (media movil guardada en nueva tabla render_timings, poblada empiricamente en cada corrida real, no estimada por LLM).
- Trabajo nuevo: endpoint GET /projects/:id/budget que sirve budget_ledger + estimated_remaining_seconds calculado en Ruby puro. Cero tokens adicionales.

### 6.12 — Razonamiento del Showrunner (mejora #12) — la mas delicada de exponer

- UI: "Why this story?" con senales detectadas + estructura elegida (flechas Discovery -> Suspense -> Supernatural reveal -> Emotional ending).
- Fuente de datos: reasoning.chosen_structure = traduccion display de NarrativeBeats.assign(n_scenes) (los beats reales, mapeados 1:1 a labels de producto via BEAT_DISPLAY_LABELS, nunca mostrando el nombre interno del beat).
- detected_signals: esta es la parte que si se hace mal, revela el mecanismo (riesgo v1 §12). No debe decir "el modelo selecciono bs_006 con genes [...] del catalogo". Debe decir algo como "El modelo detecto: misterio oculto, revelacion emocional, final de sacrificio", generado por el mismo DisplayComposer (6.1) a partir de story.preserved_genes + tone, con la misma tabla de labels que usa el bloque de "Story DNA" (6.4), para que el usuario perciba coherencia entre ambas superficies sin que ninguna exponga el ID del catalogo interno.
- Regla dura: ningun endpoint publico debe serializar base_story_id fuera de contextos de admin/debug. DisplayComposer es el unico punto de traduccion catalogo->lenguaje de producto.

### 6.13 — Regeneracion parcial (mejora #13)

- UI: por escena, botones [Regenerate], [Make darker], [Add rain] (modificadores en lenguaje natural).
- Ya cubierto estructuralmente por 6.2 (Screenwriter.regenerate_scene!) para "regenerar guion/shots de la escena". Para modificadores tipo "mas oscuro"/"agregar lluvia" despues de que el shot ya tiene un visual_prompt fijado: se antepone el modificador al visual_prompt existente y se vuelve a invocar solo VideoSynth para ese shot_id, nunca se re-invoca Screenwriter completo por un ajuste de video.
- Trabajo nuevo: VideoSynth.regenerate_shot!(shot:, client:, workdir:, resolution:, modifier: nil), reusa client.submit_with_retries existente en HappyHorseClient. ConsistencyEnforcer debe re-aplicarse al resultado para no perder los descriptores fijos al concatenar el modificador: si el modificador empuja el visual_prompt mas alla de MAX_TOTAL_PROMPT_CHARS, hay que priorizar mantener los descriptores fijos y truncar el modificador, nunca al reves.

### 6.14 — Variantes de final (mejora #14)

- UI: despues del render, "Generate Ending A / B / C".
- Implementacion: re-ejecutar solo la(s) ultima(s) escena(s) con beat "aftermath"/"revelation" con distintas variaciones de texto en Screenwriter. HappyHorse no expone seed determinista por request en submit_t2v/submit_i2v, asi que la variacion real viene de usar 3 visual_prompts distintos generados por 3 llamadas Qwen separadas de bajo costo, no de un parametro de seed en el video.
- Costo: 3x el costo de render de una sola escena final, no del corto completo, debe comunicarse explicitamente en la UI ("Generar variantes cuesta ~X creditos adicionales").
- Manifest: cada video_jobs entry de una variante lleva variant_of: <shot_id original> (ya reflejado en el schema v2, Seccion 5).

### 6.15 — Metrica de coherencia (mejora #15)

- UI: 3 barras (Narrative Coherence 92%, Visual Consistency 88%, Character Consistency 95%).
- Diferencia con Quality Meter (6.5): el Quality Meter es subjetivo/creativo (drama, accion); Coherence Metrics es objetivo/estructural.
  - visual_consistency / character_consistency: calculables al 100% en Ruby, sin LLM, verifican que ConsistencyEnforcer.apply! inserto protagonist_bible/cargo_bible en cada shot["visual_prompt"] sin truncamiento que los cortara.
  - narrative_coherence: requiere juicio semantico, no es gratis en Ruby. Para el MVP: heuristica basada en que NarrativeBeats.assign haya cubierto los beats de mas prioridad (climax, revelation); si estan presentes, score alto.
- Componente: `Showrunner::CoherenceMetrics.score(screenplay, selection)`, Ruby puro, nuevo, cero tokens.

### 6.16 — Copiloto creativo (mejora #16)

- UI: mientras el usuario escribe el prompt inicial, sugerencias en vivo ("Make it tragic", "Add a twist", "Increase horror", "Add irony", "More emotional").
- Diseno de costo: esta es la unica mejora que exige latencia baja + llamadas frecuentes, el mayor riesgo de presupuesto de tokens de las 17 mejoras si se implementa ingenuamente.
- Mitigacion: (a) debounce agresivo en frontend (>=800ms sin tecleo), (b) modelo mas barato de la tabla de QwenRouter (nuevo stage :suggest, override por ENV["QWEN_MODEL_SUGGEST"]), (c) las sugerencias NO consumen del token_budget del proyecto, corren contra un ledger separado y mucho menor, especifico de UX de composicion (ui_assist_ledger vs budget_ledger).
- Componente: `Showrunner::PromptCopilot.suggest(partial_prompt, ledger: ui_assist_ledger, config:)`, llamada unica (no batch), max_tokens bajo (<=60), response_format :json con schema {"suggestions": [string, string, string]}.

### 6.17 — Vender el Showrunner (mejora #17)

Ya cubierto en Seccion 4 como decision transversal. Complemento: el pipeline visible de 8 pasos (Seccion 4) debe coexistir con los checkpoints pausables de 6.2, es decir, el paso "Guion escrito" en la practica se detiene ahi y espera aprobacion de storyboard antes de continuar a "Renderizando Escena 1". La UI debe comunicar esa pausa como parte natural del pipeline ("Guion listo, revisa el storyboard antes de continuar"), no como una interrupcion inesperada.

---

## 7. Cambios en el modelo de datos Rails (incrementales sobre v1 §7)

| Tabla | Cambio | Motivo |
|---|---|---|
| projects | + status: awaiting_storyboard_approval (enum) | 6.2 |
| projects | + direction(jsonb): director_influence, camera_style, color_grade, music_style, voice_style | 6.6-6.10 |
| projects | + genes_override(jsonb, array) | 6.4 |
| shots | + locked(boolean, default: false) | 6.13, evita que una regeneracion de escena toque un shot ya aprobado explicitamente |
| shots | + variant_of(references shots, optional) | 6.14 |
| render_timings (nueva) | id, project_id, n_shots, resolution, total_seconds | 6.11, media movil para estimar tiempo de render |
| ui_assist_ledger_entries (nueva) | id, project_id, tokens_used, at | 6.16, ledger separado del token_ledger_entries de v1, nunca se mezclan en el mismo total mostrado como "presupuesto del corto" |

story_catalog_entries y domain_catalog_entries (v1) permanecen sin cambios y siguen sin ser accesibles desde ningun endpoint publico, regla reforzada, no relajada, por la mayor superficie expuesta en reasoning/display.

---

## 8. QwenRouter — stages nuevos (incremental sobre v1 §8 / codigo real en qwen_router.rb)

El codigo actual ya soporta stage: arbitrario con override por ENV["QWEN_MODEL_#{STAGE}"], no requiere cambios estructurales, solo declarar los stages nuevos y su costo esperado:

| Stage nuevo | Uso | max_tokens tipico | Modelo por defecto |
|---|---|---|---|
| :quality_score (opcional, 6.5 opcion B) | Scoring drama/action/ending | ~100 | barato (mismo perfil que :classify) |
| :suggest (6.16) | Copiloto creativo | ~60 | el mas barato disponible |
| :regen_scene | Regeneracion parcial de 1 escena (6.2/6.13) | igual que :scriptwrite pero con max_scenes: 1 | igual que :scriptwrite |

Ninguno de estos stages requiere tocar QwenRouter.call/call_json, es reutilizacion directa de la interfaz existente.

---

## 9. HappyHorseClient — sin cambios de contrato (referencia)

submit_t2v, submit_i2v, submit_batch, submit_with_retries, poll_until_done se reutilizan sin modificacion para: render inicial (Seccion 4), regeneracion de shot con modificador (6.13), variantes (6.14). La unica extension posible de bajo riesgo es exponer un parametro client_metadata: opcional que viaje en submit_batch para correlacionar variant_of en el callback del bloque.

---

## 10. Presupuesto de tokens — politica ampliada (incremental sobre v1 §10)

- El token_budget del proyecto (fijado por el usuario al crear el corto) cubre exclusivamente: clasificacion de tono, guionado, compresion de storyboard, y regeneraciones parciales explicitas del usuario (6.2, 6.13, 6.14).
- El copiloto de composicion (6.16) tiene su propio ledger (ui_assist_ledger_entries), con un tope fijo bajo por sesion (ej. 500 tokens), independiente del token_budget del corto, para que probar prompts en el copiloto nunca reduzca el presupuesto que el usuario ve reservado para el render.
- Quality Meter y Coherence Metrics se calculan, para el MVP, con heuristicas Ruby de costo cero (6.5, 6.15), decision explicita para no comprometer el criterio de juzgamiento de "calidad bajo presupuesto limitado" con metricas de vanidad.
- El budget_ledger mostrado en UI (6.11) nunca debe incluir silenciosamente el ui_assist_ledger en el mismo numero, deben mostrarse como dos barras separadas si ambas estan activas, para mantener la promesa de transparencia que es en si misma una feature demostrable.

---

## 11. Riesgos y mitigaciones (incremental sobre v1 §12)

| Riesgo | Mitigacion |
|---|---|
| Exponer reasoning/display termina filtrando el mecanismo del catalogo interno (genes/base_story_id) | DisplayComposer como unico punto de traduccion; regla dura de no serializar base_story_id/nombres de constantes internas fuera de contextos admin (6.12) |
| Director Mode genera contenido que imita/atribuye estilo a persona real sugiriendo respaldo | Los nombres de director son solo etiquetas de UI mapeadas a perfiles tecnicos de iluminacion/ritmo; nunca se envian nombres propios al prompt de generacion de video (6.6) |
| Musica de stock sin licencia clara compromete el requisito "sin musica con copyright de terceros" | Biblioteca curada y documentada con licencias en assets/music/LICENSES.md, sin generacion de musica por IA en el alcance del MVP (6.9) |
| Copiloto creativo dispara demasiadas llamadas y compromete el presupuesto de tokens | Debounce >=800ms, modelo mas barato, ledger separado con tope fijo, nunca compartido con token_budget del corto (6.16, 10) |
| Regeneracion parcial con modificador rompe continuidad al truncar los descriptores fijos | Priorizar en el truncado los descriptores fijos sobre el modificador del usuario, nunca al reves (6.13) |
| Variantes de final sin seed determinista en HappyHorse generan resultados no reproducibles | Documentar explicitamente que la variacion viene de 3 visual_prompts distintos generados por Qwen, no de un parametro de seed en DashScope |
| Storyboard preview requiere partir ShowrunnerEngine#run! en dos fases bajo presion de deadline | Es el unico cambio estructural obligatorio de todo este documento; priorizarlo en la semana 3 del roadmap antes que cualquier mejora cosmetica |

---

## 12. Roadmap de 6 semanas — ajustado a v2 (reemplaza v1 §11)

| Semana | Milestone v2 |
|---|---|
| 1 | (ya cubierto por el codigo existente) ShowrunnerEngine, StoryEngine, EntityBible, NarrativeBeats, QwenRouter, HappyHorseClient funcionando end-to-end via CLI/dry_run. |
| 2 | Rails skeleton: Project, Screenplay, Shot (+ columnas nuevas Seccion 7), ShowrunnerController, integracion de ShowrunnerEngine como ActiveJob con progress_callback: -> ActionCable (Seccion 4). |
| 3 | Split de ShowrunnerEngine#run! en plan!/render! (6.2), prioridad maxima estructural. DisplayComposer (6.1/6.12), GENE_DISPLAY_LABELS, BEAT_DISPLAY_LABELS. Storyboard UI (Hotwire) + boton de aprobacion. |
| 4 | Direction controls: camera_style (6.7), color_grade (6.8, tabla COLOR_GRADE_PRESETS), Director Mode (6.6, DIRECTOR_INFLUENCE_PROFILES). Budget UI (6.11, endpoint + render_timings). |
| 5 | Regeneracion parcial (6.2/6.13), variantes (6.14), Quality Meter + Coherence Metrics (heuristicas Ruby, 6.5/6.15). Biblioteca de musica curada (6.9). |
| 6 | Copiloto creativo (6.16, si el tiempo lo permite, es la mejora de menor prioridad relativa por riesgo de presupuesto/latencia bajo deadline). Endurecimiento end-to-end, grabacion del demo de 3 min mostrando el pipeline de 8 pasos + storyboard approval + budget ledger visible, diagrama de arquitectura actualizado (Ruby puro, sin Python), despliegue Alibaba Cloud, escritura de la entrega. |

Nota de priorizacion explicita para el equipo: si hay que recortar por tiempo, el orden de valor demostrable para los jueces es: (1) Seccion 4 pipeline visible + 6.11 budget ledger, ya casi gratis, datos existentes; (2) 6.2 storyboard preview, el cambio estructural, mayor impacto en "sensacion de control"; (3) 6.1/6.12 ficha de produccion + razonamiento, impacto de percepcion alto, costo bajo (DisplayComposer no llama a ningun LLM nuevo); (4) todo lo demas, en el orden de la tabla de la Seccion 6 por relacion esfuerzo/impacto ya anotada en cada subseccion.

---

## 13. Apendice — Glosario incremental (extiende v1 §13)

- DisplayComposer — modulo Ruby unico responsable de traducir datos internos del catalogo (genes, base_story_id, beats) a lenguaje de producto (display, reasoning), sin exponer nunca el mecanismo interno.
- Checkpoint de storyboard — punto de pausa obligatorio entre plan! y render! donde el usuario puede aprobar, editar o regenerar antes de gastar creditos de HappyHorse.
- Quality Meter vs Coherence Metrics — el primero es una heuristica de percepcion creativa (drama/accion/final); el segundo es una verificacion estructural/mecanica de que ConsistencyEnforcer y NarrativeBeats cumplieron sus garantias. No deben confundirse en la UI ni en el codigo.
- UI Assist Ledger — presupuesto de tokens separado y acotado, exclusivo del copiloto creativo de composicion, nunca mezclado con el budget_ledger del corto.
