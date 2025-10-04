Phase 5 — Integration, Hardening, and Polish

Scope
- Finalize tolerant mode behavior and quality across the codebase:
  - Stabilize semantics (ordering, determinism, position accuracy).
  - Ensure strict mode remains unaffected and performant.
  - Document options and recommended defaults.
  - Add comprehensive tests (cascade, nested, and stream operations) and measure performance.

Objectives
- Behavioral correctness
  - Maintain single-token-per-call invariant, including EOF draining (one pending error per call).
  - Preserve token ordering for pre-inserted tokens (anchors) vs error tokens vs structural insertions.
  - Enforce stop-before sync semantics and bounded scanning; never consume anchors.
  - Deterministic outputs: checkpoint/rewind must reproduce identical streams.
  - Accurate metas: synthetic tokens carry zero-length or minimal spans without corrupting following positions.

- Test coverage
  - Cascade scenarios: multiple errors in a row with mixed classes (e.g., map + identifier + terminator + ternary).
  - Nested contexts: errors inside interpolations, strings, sigils, heredocs; mismatches inside interpolation.
  - Strict vs tolerant parity: strict behavior unchanged (no recovery), tolerant always produces tokens to EOF.
  - Stream operations: next/peek/peek_n/pushback/position/rewind around errors and synthetic insertions.
  - Version-gated bidi/break tests for comments/strings/dot-comments (align with Elixir versions).
  - Fuzz: randomized inputs with injected control/bidi/break characters; assert forward progress and no crashes.

- Performance and resilience
  - Tolerant with no errors: < 5% overhead vs strict.
  - Error-path bounded: recovery cost linear in error span; bounded attempts in peek/peek_n refill cycles.
  - Avoid pathological retries; verify :error_max_skip caps scanning.

- Developer ergonomics
  - Document options: error_mode, error_sync ([:semicolon, :newline, :closer, :comma]), error_max_skip, insert_structural_closers, existing_atoms_only.
  - Provide migration guide: enabling tolerant mode, structural insertions, and recommended syncs.
  - Clarify error_token reason shape and meta conventions; examples for common error categories.

- Optional (nice-to-have)
  - Identifier sanitization (opt-in): synthesize sanitized/truncated identifiers/atoms for mixed-script/confusable/length errors.
  - Synthetic token tagging: meta.extra flag (e.g., :synthetic) for downstream consumers to distinguish.
  - Configurable ternary strategy: choose emit/skip for ..// variants.

Work Items
- Tests (add/extend)
  - EOF draining: strings/sigils/quoted/heredocs/interpolation terminators; ensure one-error-per-call and end tokens synthesized when enabled.
  - Nested interpolation: begin/end markers emitted correctly; missing terminator inside interpolation recovers with expected synthesis.
  - Map % errors: % {, %(, %[, including whitespace after %, verify standalone % precedes error and next delimiter is visible.
  - Consecutive semicolons: error on second; stream contains single ; between expressions; continuation verified.
  - Ternary: ..// with and without extra /; synthesized :..// present only for the missing-slash case.
  - Stream operations: tolerant next/peek/peek_n/pushback/position/rewind around back-to-back errors.
  - Strict guards: strict next/peek/peek_n unchanged on error; no tolerant fallback, no delays/timeouts.

- Fixes and refinements
  - Token ordering: enforce pre_inserted (anchors) before error_token, before structural insertions.
  - Synthetic metas: audit zero-length vs minimal spans to avoid shifting positions; ensure start_pos/pre_terms capture aligns with buffer entries.
  - Whitespace consumer: replace ad-hoc space handling with a small helper that consumes only horizontal spaces and escaped newlines (never newline), reused where needed.
  - Strict/tolerant separation: re-check strict branches in TokenStream to prevent tolerant recovery from activating in strict suites.
  - Type-checker stability: isolate/elide code paths that triggered 1.19-rc type checker issues (use guards and smaller helpers, no deep nested cond).

- Documentation
  - Update TOLERANT_MODE_GPT.md with Phase 2–4 decisions (defaults, synthesis behaviors, targeted recoveries) and Phase 5 outcomes.
  - Add README section for error_token anatomy, options, and quick examples.
  - Add CHANGELOG entry for tolerant mode enhancements.

Deliverables
- Green test suites:
  - All existing strict tests pass unchanged.
  - Tolerant suites cover all strict error cases with recovery and continuation.
  - New cascade/nesting/stream operation tests pass.
- Benchmarks:
  - Report on tolerant vs strict overhead with/without errors.
- Documentation updates completed and reviewed.

Success Criteria
- Behavioral:
  - Forward progress guaranteed; no infinite loops; bounded scanning always terminates.
  - Deterministic token streams; checkpoint/rewind produces identical tokens and metas.
  - Token ordering: anchors (% or inserted openers) precede error_token; structural insertions follow.
- Quality:
  - All tests pass consistently (no timeouts) across supported Elixir versions.
  - Performance budget met (< 5% overhead, happy path).
  - No regressions against strict behavior.

Risks & Mitigations
- Version-gated behavior (bidi/break rules differ across Elixir versions):
  - Mitigate via conditional tests and feature detection.
- Synthetic tokens alter expectations in existing tests:
  - Mitigate by asserting presence/continuation rather than exact sequences where synthesis is enabled.
- Type-checker instability on deep pattern matches with 1.19-rc:
  - Keep helper functions shallow; avoid highly nested conditions; keep pattern scopes localized.

Timeline (suggested)
- Week 1: Test expansion (cascade, nested, stream ops), fix ordering and meta consistency issues; stabilize strict suites.
- Week 2: Performance pass (micro-bench, bounded retries), docs, finalize defaults (insert_structural_closers), and add optional features behind flags.

Open Decisions
- Default for insert_structural_closers: enable by default (current) vs opt-in.
- Synthetic token tagging in meta.extra: introduce now vs defer to consumer feedback.
- Identifier sanitization: include in Phase 5 (if time) vs future phase.

