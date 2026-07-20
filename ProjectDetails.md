# Ruby Showrunner

## Inspiration

Generative video can produce an impressive individual shot, but a sequence often falls apart as soon as the camera cuts. Characters change faces or proportions, props change color and size, locations lose their geometry, and physical interactions stop making sense. A visually attractive frame is not enough to make a coherent film.

Ruby Showrunner was inspired by that gap between generating clips and directing a production. We wanted to build a generic filmmaking system that treats consistency as a first-class production requirement. The goal is not limited to fictional characters or one demonstration story: the same identity, scale, continuity, and physical constraints must also apply to human performers, real locations, recurring objects, and any short-film concept submitted by a user.

## What it does

Ruby Showrunner transforms a story prompt and cinematic preferences into a complete short film. It validates the source, forecasts token consumption, writes a structured screenplay, builds a canonical visual bible, generates character and location references, compiles a shot-by-shot storyboard, renders video clips, adds audio, and assembles the final MP4.

The application provides two operating modes. Automatic mode resolves unspecified decisions and attempts to complete the production with safe defaults and bounded repair. Full Control mode lets the filmmaker approve the storyboard, regenerate an individual asset, shot, or scene, retry visual QA, authorize additional tokens, or explicitly accept a remaining visual-only risk for a requested render.

Its Consistency Gate evaluates the structural contract, script consistency, source-to-asset fidelity, and storyboard vision. Visual QA measures identity, recurring props, scale, and physics independently, so a high average cannot conceal a character with the wrong dimensions. A second QA stage samples the generated video before final delivery.

## How we built it

We built Ruby Showrunner as a Ruby 3.4 and Rails 8 application with PostgreSQL, pgvector, Redis, Sidekiq, Turbo, Stimulus, and Action Cable. Long-running planning and rendering execute asynchronously, while the interface receives live production progress.

Qwen powers screenplay reasoning, source analysis, prompt compilation, and visual evaluation. DashScope image generation creates canonical references and storyboard frames, while HappyHorse synthesizes the video clips. FFmpeg and ffprobe normalize media, verify audio streams, and assemble the final cut.

The production pipeline is organized into six stages: narrative contract, canonical visual bible, storyboard contract, storyboard visual QA, video production, and edit and delivery. Instead of prompting every shot independently, the system creates persistent contracts for characters, props, locations, scale, movement, and physics. Those canonical facts are injected into every relevant shot.

We also implemented a durable, content-addressed media store. Expiring provider URLs are downloaded and validated while they are still available, then reused by the UI, QA, regeneration, and video pipeline. Project manifests retain the screenplay, production bible, continuity state, QA findings, token accounting, repair history, and final-video ledger.

## Challenges we ran into

The hardest challenge was dimensional consistency. Our initial foosball story revealed the problem clearly: a player that should have been a small figure attached to a metal rod was repeatedly generated as a full-size fantasy character standing on the table. Regeneration alone did not solve it because the prompts lacked an explicit scale and physical-state contract.

We also encountered identity drift, changing ball sizes and colors, unrelated character reference images, disappearing regeneration controls, expired remote image URLs, partial visual-QA results, missing audio, accidental labels in production frames, and repeated repair cycles that consumed tokens without converging.

Distributed execution introduced another class of problems. Rails and Sidekiq could observe different media availability or job state, workers could retain old code until restart, and a refresh could make an asynchronous operation appear inactive. Provider timeouts, malformed responses, signed URLs, and separate token and media-credit limits all had to become explicit operational states rather than silent failures.

## Accomplishments that we're proud of

We are proud that Ruby Showrunner evolved from a linear generation demo into a contract-driven production system. It now preserves a canonical source of truth from the original prompt through the final render and identifies exactly which shot and consistency dimension failed.

The visual gate cannot pass scale errors by averaging them with stronger scores. Calibration images are isolated from narrative media, provider references survive URL expiration, and targeted regeneration does not invalidate unrelated approved work. Automatic repair is deliberately bounded, preventing an infinite cycle of rerendering and discovering new failures.

We are also proud of the balance between automation and authorship. Automatic mode can resolve defaults and finish a film, while Full Control gives the operator precise recovery and rendering controls. The token predictor estimates production and repair demand before expensive work begins, and one-shot overrun authorization gives users control over difficult projects without removing quality safeguards.

## What we learned

We learned that consistency cannot be repaired only at the final prompt. It must be designed into the entire pipeline, beginning with source validation and continuing through structured screenplay data, canonical references, shot compilation, persistent media, visual QA, video QA, and final assembly.

We learned to separate creative freedom from continuity constraints. Camera movement, lenses, framing, color, rhythm, and cinematic style can remain expressive, while identity, anatomy, wardrobe, object dimensions, spatial relationships, and physical rules must stay locked unless the story explicitly changes them.

We also learned that a production system must distinguish unavailable evidence from a failed score, tokens from provider credits, technical references from story frames, and recoverable work from final approval. Clear state and bounded retries are as important as model quality when real money and long-running jobs are involved.

## What's next for Ruby Showrunner

The next step is to move canonical media from local disk to shared object storage so multiple web and worker instances can operate reliably in production. We also plan to add stronger authentication and project isolation, provider-independent adapters, richer cost telemetry, and resumable production across deployments.

On the creative side, we want to expand temporal continuity analysis beyond sampled frames, improve human face and wardrobe locking, model scene geometry in greater detail, and validate motion trajectories and object interactions across consecutive clips. A comparative evaluator could automatically select the best result from several candidates without changing the approved creative contract.

Finally, we want Ruby Showrunner to become a reusable orchestration layer for consistent AI filmmaking: a system where creators can change models and cinematic styles while keeping the screenplay, visual identity, physical world, production history, and editorial intent under reliable control.
