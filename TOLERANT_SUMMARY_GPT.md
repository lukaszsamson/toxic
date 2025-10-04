# Tolerant Mode – Implementation Summary (GPT)

This summary reviews the current tolerant mode implementation against the design in TOLERANT_MODE_GPT.md and TOLERANT_MODE_COMPARISON.md, and the phase validation reports PHASE1_VALIDATION.md through PHASE5_VALIDATION.md. It highlights what is implemented, what diverges from spec, and what needs further work.

## Sources Reviewed
- Design: TOLERANT_MODE_GPT.md, TOLERANT_MODE_COMPARISON.md
- Code: lib/toxic/driver.ex, lib/toxic/token_stream.ex, lib/toxic/tokenizer.ex, lib/toxic/interpolation.ex, lib/toxic/terminator.ex, plus supporting modules
- Tests: test/toxic_tolerant_mode_test.exs, test/toxic_erros_test.exs
- Phase reports: PHASE1_VALIDATION.md, PHASE2_VALIDATION.md, PHASE3_VALIDATION.md, PHASE4_VALIDATION.md, PHASE5_VALIDATION.md

## High‑Level Status
- Core tolerant mode is implemented end‑to‑end.
- Driver performs tolerant recovery, emits {:error_token, meta, reason}, and (optionally) synthesizes structural tokens.
- TokenStream integrates tolerant fallback paths for next/peek/peek_n, buffering, and position.
- Structural synthesis is implemented and ON by default.
- Context‑specific recovery and identifier sanitization are implemented behind flags (both default to true in code).
- Most gaps reported in earlier phase validations have been addressed in the current code.

## Phase‑by‑Phase Evaluation

### Phase 1: Driver plumbing + basic recovery
Implemented
- Options threaded through Driver and TokenStream: `:error_mode`, `:error_sync` ([:semicolon, :newline, :closer, :comma]), `:error_max_skip` (4096), `:insert_structural_closers`, `:insert_identifier_sanitization`.
- Strict vs tolerant branching: errors convert to error_token in tolerant mode; strict mode still returns `{:error, ...}`.
- scan_to_sync/3 with unified “stop before, do not consume” sync points: semicolon, newline (\n, \r\n), comma, closer (via current_terminators), comment (`#`), and horizontal whitespace (space, tab, ff, vt).
- Forward progress guarantee: always consume at least one grapheme if no sync hit.
- Deferral flushing before error emission to preserve EOL coalescing order.
- Grapheme‑cluster aware advancing using `:unicode_util.gc/1` in both consume_one and do_scan_to_sync.

Gaps/Notes
- None blocking. CRLF handling is acceptable (newline detection considers `\r\n`), consistent with design notes.

### Phase 2: Structural synthesis and EOF draining
Implemented
- EOF draining: `pending_error/1` detects missing interpolation/context/scope; `emit_pending_error/2` emits one error token per `next/2` call and mutates state to progress.
- Structural synthesis (gated by `insert_structural_closers`):
  - Missing interpolation → error_token then `{:end_interpolation, ...}`
  - Missing string/sigil/heredoc/quoted identifier → error_token then appropriate `*_end` token
  - Missing scope terminator → error_token then expected closer (e.g., `:")"`, `:"]"`, `:"}"`, `:">>"`)
- Terminator stack management: push/pop logic in synthesis helpers, zero‑length metas for synthetic tokens.
- Default for `insert_structural_closers` is true in both TokenStream and Driver.

Gaps/Notes
- None significant. Ordering is correct: deferrals → error → structural insertions.

### Phase 3: TokenStream integration (fallback tolerant path)
Implemented
- Driver `recover/3` delegating to `emit_error_and_advance/3` in tolerant mode.
- TokenStream tolerant handling:
  - `next/1`: if `stream.error` and tolerant → `recover_next/1`
  - `peek/1`: recover into buffer then peek
  - `peek_n/2`: fills via `ensure_buffer_size/2`; if still short and tolerant, uses `fill_for_peek/3` to recover/refill and retry
  - `position/1`: recovers into buffer when needed to ensure deterministic next‑token start
  - Buffer entries store `{token, pre_terms, pre_pos}` for accurate pushback/rewind

Gaps/Notes
- Residual TODO comment in `to_stream/1` on error halting is harmless; tolerant mode should never hit that path.

### Phase 4: Context‑specific recovery
Implemented via `adjust_recovery/6` extension point that overrides default scan when certain error messages/token chars are detected.
- Keyword spacing `foo:bar` → consume only `:` to preserve following identifier.
- Map errors `% {}`, `%(`, `%[` → emit `%` first (anchor), consume `%` and leading spaces, then error continues and following delimiters tokenize normally.
- Alias followed by `(` → synthesize opening `:("(" )` with proper terminator stack update; consume the actual `(`.
- Consecutive semicolons `;;` → emit a single `;` and consume the extra; error token accompanies the second.
- Ternary `..//` → emit error_token, then emit a synthetic identifier token `:..//` at the error span (inserted after the error).

Gaps/Notes
- Token ordering and whitespace‑after‑`%` issues reported earlier in Phase 4 report are fixed: output order is now `pre_inserted ++ [error_token] ++ post_inserted ++ inserted_struct`, `%` is pre‑inserted and spaces after `%` are consumed.

### Phase 5: Integration & hardening, identifier sanitization
Implemented
- Identifier sanitization (flag: `insert_identifier_sanitization`, default true in code):
  - Error message parsing to detect identifier/atom error classes (mixed script, confusable, NFKC, unsafe/existing atoms only, atom length).
  - Confusable skeleton via `String.Tokenizer.Security.confusable_skeleton/1` with safe fallback.
  - NFKC normalization (`:unicode.characters_to_nfkc_list/1`).
  - ASCII‑friendly mapping with replacement to `_`, truncation to 255 bytes, and `ensure_ident_start/1`.
  - Emission as an inserted token attached to the recovery step. Current implementation marks sanitized identifier as a post‑error insertion, so it appears immediately after the error token.
- Additional utilities: consume leading horizontal whitespace (with escaped newline handling), helper predicates, and message parsing to robustly match error categories.
- Extensive tolerant tests added, including synthesis, cascade/nested cases, sync points, and context specifics.

Gaps/Notes
- Ordering of the sanitized identifier vs. error token: some tests (Identifier sanitization section) expect the sanitized identifier to appear before the error token; the current implementation intentionally inserts it after the error (`{:post_error, id_token}`). This mismatch should be resolved by choosing a single policy and updating tests/spec accordingly.
- `identifier_sanitization_candidate?/2` still depends on `rest != []`. Since the tokenizer has usually consumed the offending identifier, `rest` often starts with a delimiter; this guard can suppress sanitization in some cases. Consider removing the `rest` dependency and key the decision entirely on the error class.
- Minor duplication: two `identifier_sanitization_candidate?` branches exist inside `adjust_recovery/6` (one post‑error, one pre‑inserted). Only the first matches; the second is redundant and should be removed to avoid confusion.
- Documentation mismatch: TOLERANT_MODE_GPT.md originally proposed `insert_identifier_sanitization` default false; code defaults to true and tests rely on it. Update docs to reflect current default.
- Phase 5 report flagged Dialyzer warnings and a few failing tests (ordering and sanitization). The codebase now appears aligned with the intended behavior (ternary as post‑error, `%` anchoring, consecutive semicolons). We did not execute the test suite here; run locally to confirm and adjust tests/specs where expectations diverge from the finalized design.

## Cross‑Cutting Observations
- Sync points honor “stop before, don’t consume”, preserving separators for downstream parsing.
- Grapheme cluster advancement is implemented consistently for both minimal progress and scanning.
- Error token metas are ranged with exclusive end; structural insertions use zero‑length metas at the insertion point (good for downstream consumers).
- Deferral/EOL ordering is preserved: deferrals flush before error tokens to avoid “EOL after error” anomalies.
- Checkpoint/rewind determinism is supported via pre‑snapshot `{pre_terms, pre_pos}` and buffer entries; add explicit tests to lock this in.
- Strict mode behavior is preserved; strict tests in test/toxic_erros_test.exs validate compatibility with Elixir’s tokenizer error tuples.

## Divergences vs. Design Docs
- `insert_identifier_sanitization` default: code uses true; GPT doc proposed false. Align the doc to the implementation (or change default if desired).
- MVP vs. synthesis: the final implementation adopts synthesis by default (closers, end_interpolation, string ends), consistent with the post‑comparison decision but stricter than GPT’s MVP suggestion.

## What Needs More Work
1. Identifier sanitization
   - Decide and standardize ordering relative to error_token (pre‑error vs post‑error) and update tests/spec accordingly.
   - Simplify `identifier_sanitization_candidate?/2` by dropping `rest` checks; rely on parsed error message class.
   - Remove duplicate/unreachable sanitization clause in `adjust_recovery/6`.
2. Tests and determinism
   - Add/refresh tests for checkpoint/rewind determinism across error tokens and inserted structurals.
   - Verify `peek_n/2` tolerant behavior with explicit tests (it is implemented).
3. Documentation & tooling
   - Update TOLERANT_MODE_GPT.md to reflect current defaults and behavior (identifier sanitization, synthesis default).
   - Add README section on `:error_token` anatomy and tolerant options (`:error_mode`, `:error_sync`, `:error_max_skip`, `:insert_structural_closers`, `:insert_identifier_sanitization`).
   - Consider CHANGELOG entry for tolerant mode landing and option defaults.
4. Performance & fuzzing
   - Add quick benchmarks for tolerant vs. strict overhead and validate bounded scanning behavior (`:error_max_skip`).
   - Add fuzz tests for control/bidi/break characters and long inputs.
5. Minor cleanup
   - Prune stale TODOs and redundant branches (e.g., duplicate sanitization clause).
   - Consider tightening meta construction helpers and unify any remaining token ordering comments.

## Conclusion
The tolerant mode implementation is comprehensive and robust:
- Driver‑centric recovery with sync scanning and structural synthesis
- End‑to‑end integration in TokenStream (next/peek/peek_n/position/buffer)
- Context‑specific recovery hooks and EOF draining
- Unicode/grapheme correctness and deferral ordering preserved

Most earlier phase validation gaps have been addressed. The remaining work is primarily consolidation and polish: standardize identifier sanitization ordering and guards, finalize docs/tests, and add determinism/performance checks. With these refinements, tolerant mode is production‑ready and aligned with the synthesized design goals.

