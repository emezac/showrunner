# Narrative and edit pipeline v3

The screenplay is the authoritative contract for story, generation and final
editing. It is no longer treated as a flat list of visual prompts.

## Stages

1. `StoryArchitect` generates a premise, selects a structure and creates causal
   scene cards without camera instructions.
2. `Screenwriter` converts the approved cards into filmable shots. Scene-card
   objectives, turns, outcomes and order are merged back deterministically so a
   second model call cannot silently rewrite the story.
3. `ScreenplayPlanner` upgrades generated, user-authored and legacy scripts to
   schema `3.0`. It assigns editorial roles, entry/exit states, stable unique
   IDs, dialogue timing and integer render durations.
4. `StoryboardPromptCompiler` creates bounded prompts from structured intent.
   The complete source direction remains in `source_visual_prompt`; long prose
   is reduced to a separate atomic `generation_action`.
5. `ScreenplayEvaluator` rejects missing scene/shot contracts, impossible
   dialogue timing, invalid runtime and non-atomic generation actions.
6. `EditDecisionList` preserves scene boundaries, clip order, timeline offsets,
   audio cues and motivated transitions.
7. `Editor` consumes the EDL. Cuts use FFmpeg concat while fades/dissolves use
   `xfade`; the final output is capped to the planned duration.

The visual consistency pipeline then adds canonical characters, props,
locations, physics and reference images without replacing narrative intent.

## Scene contract

Every scene includes:

- `objective`, `conflict`, `turn`, `outcome`
- `emotional_state_in`, `emotional_state_out`
- `continuity_in`, `continuity_out`
- `duration_budget`

## Shot contract

Every shot includes:

- `editorial_role` and `purpose`
- one atomic `story_event`
- `entry_state`, `exit_state` and `blocking`
- preserved explicit `camera`
- `dialogue_range` and `audio_cues`
- `transition_out`
- full `source_visual_prompt` and bounded `generation_action`

## Runtime rule

The planner allocates total clip time as:

`target film duration + transition overlaps`

The EDL subtracts overlaps on the timeline, so its `planned_duration` matches
the requested duration. Scene transitions use whole seconds because the active
video providers receive integer clip durations.

## Backward compatibility

No database migration is required. Any stored screenplay is upgraded in memory
before display, editing or render. User camera choices and source directions are
preserved; duplicate IDs and missing semantic fields are repaired automatically.
