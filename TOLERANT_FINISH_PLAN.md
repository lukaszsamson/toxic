# Tolerant Mode – Finish Plan (Terse)

## P0 – Critical Fixes (this week)
- Opener vs closer synthesis (unexpected vs mismatched closers)
  - Change `synthesize_from_reason/2` in `lib/toxic/driver.ex` to return a tagged tuple indicating synthesis side:
    - `{:opener, [token], new_scope}` for unexpected closer (needs synthetic opener before error).
    - `{:closer, [token], new_scope}` for mismatched/missing closer (synthetic closer after error).
  - In `emit_error_and_advance/3` (same file), split synthesis into pre/post groups and merge into output:
    - Prepend openers to `pre_synth`; append closers to `post_synth`.
    - Output order: deferrals, `pre_inserted`, `pre_synth`, error_token, `post_inserted`, `post_synth`.
  - Preserve zero-length metas for synthetic tokens at current position; update scope push/pop at insertion time.
  - Acceptance: with `insert_structural_closers: true`, inputs `")"`, `"]"`, `"}"`, `">>"` yield `:error_token`, synthetic opener, then actual closer; `"([)"` yields synthetic `:"]"` after first error.

- Ternary `..//` ordering (error first, then synthetic op)
  - Keep ternary recovery producing `{:post_error, {:identifier, ..., :..//}}` in `adjust_recovery/6` so synthetic identifier follows error.
  - Align tests to assert `[:error_token, :identifier(:..//), ...]` in `test/toxic_tolerant_mode_test.exs`.
  - Acceptance: “continue after ternary error” passes with error before `:..//`.

- Identifier sanitization must always advance (fix loop)
  - Make `identifier_sanitization_candidate?/2` depend only on parsed error class (mixed/confusable/NFKC/length), not on `rest`.
  - When sanitizing:
    - Compute `original_len` from `reason`’s `token_chars` (flatten iodata/charlist).
    - Advance `rest` by `original_len` unconditionally (even if a delimiter is next), updating line/column via grapheme scan over `token_chars`.
    - Insert sanitized identifier as a post-error token (`{:post_error, id_token}`) so ordering is stable.
    - Remove duplicate sanitization branch in `adjust_recovery/6` to avoid double insertion.
  - Acceptance: long/mixed/confusable identifiers produce exactly one error then a sanitized identifier, and tokenization continues (no retries/loops).

- Grapheme-aware advancement in all recovery paths
  - Use `:unicode_util.gc/1` for both minimal progress and bulk skips (sanitization skip), and `advance_pos_cluster/3` for position.
  - Treat `\r\n` as newline pair; ensure column resets to 1 on newline.
  - Acceptance: emoji/ZWJ sequences don’t desync columns; position assertions remain valid.

- Full-suite validation and spec alignment
  - Fix tests that destructure `:eol` metas as 3-tuples; accept 2-tuple metas where applicable.
  - Verify unexpected closer synthesis, ternary ordering, and sanitization scenarios pass; adjust expectations where the finalized behavior is intentional.

## P1 – Validation & Coverage (next week)
- Add opener synthesis tests
- Add sanitization scenarios tests
- Unskip broken peek_n tolerant tests
- Add checkpoint/rewind determinism tests
- Fix test assumptions (EOL metas)
- Specify nested error handling rules + tests (document emission order across nested interpolation/string/terminator chains)
- Position-accuracy regression tests (unicode grapheme clusters, heredocs, interpolation)

## P2 – Docs & Options (next week)
- Document error_token shape
- Document tolerant options and defaults
- Align docs with code defaults
- Add CHANGELOG entry

## P3 – Performance & Quality (following)
- Benchmark tolerant vs strict (<5%)
- Address Dialyzer warnings
- Add version-gated bidi/break tests
- Add fuzz tests for recovery paths
- Track optional `:error_limit` as flood-protection (low-priority backlog)

## Implementation Notes
- Tag synthesis result {:opener | :closer, toks}
- Order: deferrals, pre_inserted, pre_synth, error, post_inserted, post_synth
- Sanitization uses NFKC + skeleton
- Ensure minimum consume = error span
- Grapheme-aware advance everywhere

## Exit Criteria
- All tolerant tests green
- Strict tests unchanged
- Deterministic rewind with errors
- Docs updated; benchmarks recorded
