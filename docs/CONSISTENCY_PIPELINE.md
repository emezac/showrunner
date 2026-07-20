# Generic consistency pipeline

The consistency system is project-agnostic. It derives its contracts from the
user prompt and generated screenplay; no story-specific object, character or
physics rules are hardcoded.

Narrative decomposition, runtime allocation and the semantic EDL are documented
in [NARRATIVE_EDIT_PIPELINE.md](NARRATIVE_EDIT_PIPELINE.md).

## Planning

1. `AssetProfiler` extracts characters, recurring props and locations.
2. Characters receive a full-body reference and a reference-conditioned
   identity close-up. Props and locations receive canonical reference images.
3. `ProductionBible` converts those assets into immutable traits, scale anchors,
   physical constraints and forbidden mutations.
4. `ContinuityPlanner` binds the entities used by every shot, carries state from
   the prior shot, locks screen direction and chooses a render strategy.
5. `ConsistencyEnforcer` creates positive and negative prompt contracts from the
   structured data.
6. Wan 2.7 generates each storyboard keyframe with up to nine canonical input
   images, rather than relying on text descriptions alone.
7. Qwen Vision compares storyboard pixels with the canonical contract. Up to
   three failed keyframes are regenerated once with targeted corrections.

## Rendering

- A single-character shot uses that character's own R2V reference.
- Multi-character or prop-heavy shots use the approved full-composition
  keyframe through I2V.
- Expired canonical references and keyframes are automatically rebuilt.
- Legacy manifests without props are upgraded automatically before rendering.
- Generated clips are sampled into frame sequences and checked by Qwen Vision
  for identity, props, scale, temporal stability and physical plausibility.
- Up to three failed clips are regenerated once and evaluated again.
- With `CONSISTENCY_STRICT=true` (default), unavailable or failed final video QA
  stops the pipeline before editing. Set it to `false` only when explicitly
  accepting an unverified result.

## Manifest fields

- `assets.props`
- `production_bible`
- `screenplay.scenes[].shots[].continuity`
- `screenplay.scenes[].shots[].negative_prompt`
- `consistency_report`
- `video_consistency_report`

`consistency_report.structural_score` measures contract completeness. It is not
presented as pixel-level quality. Pixel and temporal results live under the two
vision reports.
