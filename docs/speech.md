# Qwen Cloud Hackathon — Track 2: AI Showrunner
## Presentation Video Speech Script (approx. 3 minutes)

---

### [0:00 - 0:30] PART 1: The Hook and The Core Problem
**Visual:** Show the main dashboard and transition to the storyboard review screen.
**Speech:**
"Hello everyone, and welcome to our presentation of the **AI Showrunner** engine, built for the Qwen Cloud Hackathon. 

Traditional video generation tools are fragmented. Creators write a prompt, get a single disjointed clip, and then struggle to stitch them together. There is no character continuity, no consistent styling, and zero emotional structure. To solve this, we built **AI Showrunner**: an event-driven Rails architecture that acts as a virtual director, orchestrating the entire short drama pipeline from a single prompt to a fully finished, edited cinematic experience."

---

### [0:30 - 1:15] PART 2: The Coherent Storytelling Engine
**Visual:** Hover over the Narrative Curve presets (Mystery, Danger, Climax) and the emotional beats list in the UI.
**Speech:**
"Every great film relies on structure. Our engine utilizes **narrative curves** to shape the story. Instead of generating random clips, the core agent structures the film across seven emotional beats: *Mystery, Curiosity, Escalation, Danger, Climax, Revelation, and Aftermath*.

This narrative structure guides the generation of the screenplay, dialogues, and camera moves. In this release, we've introduced **two production modes** to support different creative workflows:
First, **Autonomous (Agentic) Mode** — where you provide a prompt, and the agent automatically handles pre-production, visual consistency, rendering, and editing.
Second, **Interactive (Full Control) Mode** — which gives the creator direct editorial control. You can edit script dialogs, lock specific shots you like, regenerate others, tweak camera properties, and customize visual prompts before rendering a single frame."

---

### [1:15 - 2:00] PART 3: Technical Architecture & Qwen Cloud Integration
**Visual:** Show the interactive SVG architecture diagram on the `/architecture` page.
**Speech:**
"Let's look under the hood. Our backend is powered by **Qwen Cloud APIs**:
1. **The Screenwriter Module** invokes Qwen's flagship models to produce structured JSON screenplays conforming to our strict dramatic schema. If the network or APIs are offline, it gracefully falls back to a deterministic, progressive storyboard generator to keep the creator working.
2. **The Storyboarder Module** utilizes a batch compression pattern. Instead of making slow, separate LLM requests for every shot, it batches the entire screenplay's shot prompts into a single Qwen invocation, compressing descriptions to under forty tokens while preserving composition variety.
3. **The ConsistencyEnforcer** dynamically injects protagonist physical descriptors and key cargo attributes into each shot's prompt, guaranteeing strong visual continuity across cuts."

---

### [2:00 - 2:45] PART 4: Video Synthesis and Post-Production Compile
**Visual:** Show a rendering progress screen with the ActionCable live updates, then the completed video player.
**Speech:**
"For rendering, the engine translates storyboard prompts into synthesis tasks. We integrate with high-fidelity video generation APIs like **HappyHorse**. In sandbox dry-run modes, it generates color-coded still frames corresponding to the emotional beat of each scene to prevent wasting valuable credits during draft stages.

Once clips are ready, **FfmpegRunner** compiles the final film in the background. It dynamically generates complex filtergraphs to handle transition crossfades, overlays, narrator voice-overs, and custom music soundtracks. The entire background rendering process is handled by Sidekiq and broadcasted to the frontend in real-time via ActionCable websockets."

---

### [2:45 - 3:00] PART 5: Conclusion
**Visual:** Close-up of the final compiled video playing on the screen.
**Speech:**
"AI Showrunner demonstrates how advanced LLMs like Qwen can go beyond simple chat interfaces to coordinate complex, multi-layered multimodal pipelines. It bridges the gap between raw generative models and professional storytelling. 

Thank you for your time. All our code, documentation, and architecture diagrams are open-source and available on our repository. Let's make some movies!"
