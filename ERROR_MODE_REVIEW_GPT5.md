**Summary**
- The tolerant-mode implementation in `lib/toxic/driver.ex` is largely correct and aligns with the direction in `ERROR_MODEL.md`: it emits structured `:error_token` entries, preserves a linear stream, synthesizes structural tokens with zero-length metas where appropriate, and advances deterministically. Most recovery paths match the recovery table and the tests in `test/toxic_tolerant_mode_test.exs` exercise real continuation scenarios and ordering.
- There are a couple of intentional divergences from the text in `ERROR_MODEL.md` (notably handling of unexpected `end` and the precise consumption semantics for unexpected/mismatched closers). These choices are internally consistent and covered by tests, but they should be acknowledged and either documented in the model or adjusted in code/tests for parity.

**What Looks Solid**
- Error integration and control flow
  - Centralized recovery entry point with structured errors: `emit_error_and_advance/3` builds `{:error_token, meta, %Toxic.Error{}}` and continues scanning (lib/toxic/driver.ex:1024).
  - Tolerant-mode path in `TokenStream` properly defers to `Toxic.Driver.recover/3` and snapshots pre-terminators/positions for accurate pushback and position queries (lib/toxic/token_stream.ex:147, lib/toxic/token_stream.ex:382, lib/toxic/token_stream.ex:535).
- Structural synthesis
  - Synthesis is code-driven with clear sides: mismatches synthesize expected closers; unexpected closers synthesize the opener (lib/toxic/driver.ex:158-169, lib/toxic/driver.ex:1628-1664). Synthetic tokens are explicitly zero-length (lib/toxic/driver.ex:1709-1712) and appear after the error per plan.
  - Mismatched closer flow: error, synthesized expected closer, then (conditionally) emit the actual closer to keep the stream balanced and allow continuation (lib/toxic/driver.ex:1102-1148). Tests confirm ordering (test/toxic_tolerant_mode_test.exs:270-286, 1143-1171).
- EOF pending-error draining
  - `pending_error/1` prioritizes structural scope closers, then interpolation braces, then enclosing context (strings/sigils/quoted identifiers), which is a sensible order to minimize downstream cascades (lib/toxic/driver.ex:676-709). Emission helpers preserve stacks appropriately and insert zero-length closers where enabled (lib/toxic/driver.ex:934-993).
- Category coverage in tests
  - Invalid chars/VC markers, malformed numbers/floats, identifier/keyword/map errors, terminator mismatches/unexpected closers, interpolation, heredoc/sigil/string closers, sync points (semicolon/newline/comma/closer), deferral preservation, and progress guarantees are all exercised.
  - Synthetic zero-length spans are explicitly asserted (test/toxic_tolerant_mode_test.exs:1198-1215) and continuation after specific errors is verified across categories.

**Divergences From ERROR_MODEL.md (and Rationale)**
- Unexpected end (reserved_unexpected_end)
  - Model says: “Emit error; still emit :end token after error.”
  - Implementation: consumes `end` (and optional newline) during recovery and does not emit `:end` (lib/toxic/driver.ex:1185-1196, 1130-1148); deferrals are also scrubbed of any prior `:end` (lib/toxic/driver.ex:1159-1173).
  - Tests expect no `:end` re-emission (test/toxic_tolerant_mode_test.exs:294-304).
  - Suggestion: Decide and document. Either (a) update `ERROR_MODEL.md` to reflect the tested behavior (“do not re-emit reserved end”) or (b) change recovery to post-insert `:end` with zero-length meta after the error and adjust tests. Given the benefits of not re-injecting stray `:end` (less noise and simpler stacks), (a) is reasonable.
- Unexpected closer and mismatched closer consumption
  - Model notes: “For unexpected closer, do not consume closer during error span” and for mismatches “leave actual closer to be processed next”.
  - Implementation: to guarantee forward progress and stable stacks in one pass, the driver may consume the offending closer when `scan_to_sync/2` yields no movement, then re-insert the “actual closer” with zero-length meta after the error (lib/toxic/driver.ex:1120-1148, 1416-1451). For mismatches, it also synthesizes the expected closer and conditionally emits the actual closer if it matches the updated stack head (lib/toxic/driver.ex:1102-1148).
  - Tests assert the intended token stream (error, synthetic opener/closer, then actual closer), but do not assert exact error spans over the closer character (e.g., unexpected “)” and mismatched “)” cases) (test/toxic_tolerant_mode_test.exs:249-286, 1112-1171).
  - Suggestion: Either (a) update the model to allow consuming a single codepoint for progress and reinserting the closer, or (b) add an explicit `adjust_recovery` clause for `:terminator_unexpected_closer` that sets new_line/new_col without consumption and changes the “always make progress” guard to skip `consume_one/2` for this case. Option (a) keeps the current, well-tested behavior; if retained, note the meta may include the closer.

**Correctness/Assumptions Review**
- Sync points
  - `scan_to_sync/2` stops at semicolon, newline, comma, comment, horizontal whitespace, and at an expected closer if one is on the stack (lib/toxic/driver.ex:1431-1451, 1472-1519). That fits typical recovery heuristics and matches tests that assert sync on “;”, newline, “,” and closer (test/toxic_tolerant_mode_test.exs:1521-1563).
  - Note: stop-at-closer only considers the expected closer from the current stack (lib/toxic/driver.ex:1489-1505). For mismatched closers, this is intentionally not a stop, ensuring the span advances and the closer is dealt with by post-insert logic.
- Deferrals ordering
  - Deferrals (e.g., EOL, “;”, “,”) are flushed before the error to preserve ordering, which tests assert (test/toxic_tolerant_mode_test.exs:1637-1654, 1656-1670). When an error crosses a newline, pending `:eol` is dropped to avoid stale emissions, and `:end` is also dropped for the `end` case (lib/toxic/driver.ex:1150-1173). These choices avoid confusing marker placement and match expected stream order.
- Identifier sanitization
  - For identifier-domain errors, the driver optionally injects a sanitized `:identifier` after error via a post-error insertion, with NFKC normalization, ASCII skeleton, and length clamps, and special handling to pre-insert `%` in map contexts (lib/toxic/driver.ex:1337-1372). Tests cover mixed-script/confusable/length-limit cases and the disabled path (test/toxic_tolerant_mode_test.exs:612-744, 774-833).
- Category-specific recoveries
  - Alias unexpected paren: pre-inserts “(” before error so the call boundary is preserved (lib/toxic/driver.ex:1189-1201). Test matches (test/toxic_tolerant_mode_test.exs:512-530).
  - Map errors: both “space after %” and invalid open delimiters are handled with prior `%` and appropriate consumption (lib/toxic/tokenizer.ex:292-309, lib/toxic/driver.ex:1238-1255). Tests match (test/toxic_tolerant_mode_test.exs:315-353).
  - Ternary/operator special case: `..//` without trailing slash is converted to an identifier token after error (lib/toxic/driver.ex:1209-1221, 1379-1395). Tests match (test/toxic_tolerant_mode_test.exs:1066-1079).

**Test Coverage Assessment**
- Strengths
  - Good breadth across error families and sync conditions; ordering and continuation are checked repeatedly.
  - Explicit assertions that synthesis happens after error and that synthetic tokens have zero-length spans.
  - Forward progress is validated to prevent loops; EOF-draining with stacked pending errors is exercised.
- Gaps and improvements
  - Unexpected end parity: Add a focused assertion either expecting post-error `:end` or explicitly confirming its absence, and align `ERROR_MODEL.md` accordingly.
  - Error span expectations: Add a couple of span assertions for closer-driven errors to document whether the closer character is included in the error’s meta (unexpected and mismatched). This locks the chosen semantics and avoids regressions.
  - Structured error payload: A few tests asserting `err.code` on `:error_token` (e.g., for representative codes in each domain) would complement the “ordering” tests and ensure the driver is not regressing into legacy tuples. There’s a scaffold in `test/toxic/error_code_test.exs` currently `@tag :skip` (test/toxic/error_code_test.exs:6-20).
  - Interpolation nested recovery: Already covered, but consider asserting the exact order of `:begin_interpolation`, `:end_interpolation`, and string end across 1–2 more nesting shapes (some are present, e.g., test/toxic_tolerant_mode_test.exs:1221-1261, 1280-1303).
  - Existing-atoms-only path: There is a basic test; it could assert `err.code == :identifier_nonexistent_atom_when_existing_only` for clarity.

**Minor Nits and Potential Cleanups**
- `emit_error_and_advance/3` always forces one codepoint of progress if recovery coordinates don’t move (lib/toxic/driver.ex:1089-1098). That’s good, but it might be worthwhile to annotate the exceptional cases (unexpected closer, EOF) to explain why token re-insertion is used instead of leaving the character to be tokenized on the next cycle.
- `current_terminators/1` builds a combined view from scope and interpolation contexts (lib/toxic/driver.ex:1519-1594). The approach is sound; consider a brief docstring note that delimiter terminators are appended so stop-at-closer can recognize `end` and string-like delimiters as sync candidates.
- `ensure_struct/1` in `Toxic.Error` omits domain inference for a number of codes (commented clauses). It’s fine during migration but consider completing them once producers all emit structured errors to keep meta and domain consistent (lib/toxic/error.ex:592-638).

**Actionable Recommendations**
- Decide on and document the `reserved_unexpected_end` behavior
  - If you keep the current, tested behavior (no post-error `:end` emission), update the recovery table in `ERROR_MODEL.md` accordingly.
  - Otherwise, revise `adjust_recovery/5` to post-insert a zero-length `:end` and update tests.
- Lock span semantics for closer-driven errors with 1–2 span assertions so the chosen consumption policy is explicit and stable.
- Unskip or add minimal `:error_token` code assertions by domain (use the existing helper scaffold in `error_code_test.exs`).
- Optional: In comments near `emit_error_and_advance/3`, mention that re-insertion of “actual closers” is deliberate to decouple progress from scanner state and avoid stack churn.

**Overall**
- The implementation is robust and pragmatic. It meets the overarching goals: structured errors, tolerant continuation, consistent ordering, and zero-length synthetic tokens. The few noted divergences are explainable trade-offs. With minor documentation alignment and a couple of small test additions, it’s in very good shape.

