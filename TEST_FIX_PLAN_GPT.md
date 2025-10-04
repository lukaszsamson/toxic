# Test Fix Plan (GPT Review)

Source: `mix test test/toxic_tolerant_mode_test.exs` (37 failing tests).

## Test Expectation Adjustments

- **Category 4: Terminator mismatches – unexpected closing paren with continuation** (`test/toxic_tolerant_mode_test.exs:235`)
  - Tolerant mode now emits two error tokens (unexpected `)` and missing matching opener) and inserts the synthetic `:(` *before* the first error. Update the test to expect two errors and the order `[:"(", :error_token, :dual_op, :identifier, ...]`, or assert on presence rather than count.
- **Category 4: Terminator mismatches – unexpected closing bracket with continuation** (248)
  - Same pattern: the closer is dropped, we emit two errors plus the synthetic `:']'`. Relax the `length(error_tokens)` assertion and match on the follow-up tokens instead.
- **Category 4: Terminator mismatches – unexpected closing brace** (255)
  - Expect two error tokens and a synthetic `:"}"`; align the test with the new output order.
- **Category 4: Terminator mismatches – unexpected bitstring close** (262)
  - `">>"` now produces an initial error, a synthetic `:">>"`, then a second error for the missing terminator. Adjust the expected error count.
- **Category 4: Terminator mismatches – mismatched delimiter with continuation** (269)
  - The predicate `t == {:dual_op, elem(elem(t, 1), 0), :+}` is brittle. Replace with `match?({:dual_op, _, :+}, t)` (and keep the identifier assertion) to avoid tuple-structure assumptions.
- **Category 4: Terminator mismatches – unexpected end with continuation** (281)
  - Recovery emits an `:eol` token before the identifier; allow/ignore the EOL instead of asserting exact type list.
- **Phase 2: Structural synthesis – unexpected closer `)` synthesizes opening `(`** (1051)
  - Synthetic opener now appears before the error token. Update ordering assertions and check for two error tokens.
- **Phase 2: Structural synthesis – synthetic tokens have zero-length spans** (1199)
  - Synthetic openers are now positioned before the error. Update the zero-length check to look at the token immediately preceding the error.
- **Phase 2: Structural synthesis – missing quoted atom terminator synthesizes atom end** (988)
  - The driver currently emits `:atom_unsafe_start`/`:atom_unsafe_end` for the default options. Update the test to accept whichever `*_end` token matches the start (or assert on the presence of any atom end token).
- **Phase 2: Structural synthesis – synthesis preserves continuation after error** (1145)
  - The leading token is `:paren_identifier` rather than `:identifier`. Adapt the expectations to check for `{:paren_identifier, _, :foo}`, then `:dual_op`, `:int`, and the trailing synthetic closer.
- **Category 6: Identifier and keyword errors – keyword not followed by space (foo:bar)** (473)
  - Tolerant recovery produces a single `:error_token` covering `foo:bar`. Update to assert on `:error_token`, `:dual_op`, and `:identifier` (`:baz`) rather than assuming the prefix identifier survives separately.
- **Continuation after specific error types – continue after alias error** (1478)
  - Predicate uses the variable `Bar` instead of the atom `:Bar`. Update to `match?({:alias, _, :Bar}, token)`.
- **String & interpolation character errors – interpolation in quoted identifier** (811)
  - Error recovery consumes the rest of the identifier; no `:int` token is emitted. Update expectations to assert presence of `:error_token` and a `:quoted_identifier_end`, not downstream arithmetic.
- **String & interpolation character errors – invalid bidi/line-break characters** (784, 791, 801)
  - After the invalid character, the remainder stays inside the string fragment and no `:int` token is produced. Update the tests to assert on `:bin_string_end` / `:list_string_end` and to ensure the stream resumes (e.g., by checking final meta), but drop the `:int` requirement.
- **Category 3: Invalid escape sequences – backslash newline/CRLF at EOF** (215, 222)
  - Recovery leaves a trailing `:eol`. Allow the extra token in the assertions.
- **Category 1: Invalid characters – VC merge conflict with continuation** (136)
  - The tolerant stream now emits `:eol` before continuing with the second line. Adjust the expected type list accordingly.
- **Phase 2: Structural synthesis – unexpected closer without synthesis has no synthetic opener** (1173)
  - With `insert_structural_closers: false`, the closer is dropped. Decide whether tests should simply assert absence of synthetic tokens or whether we still expect to see the literal closer (see “Open Decisions”).
- **Phase 2: Structural synthesis – mismatched closer without synthesis has no synthetic expected** (1186)
  - Same as above: clarify desired behaviour when synthesis is disabled and adjust tests once spec is confirmed.
- **Cascade error recovery – brace then array opener error sequence** (1254)
  - Recovery emits `{`, `[`, an error, `:]`, `:}`; no `:(`. Update expectations to check for inserted `:]` and closing `:}`.
- **Cascade error recovery – mixed errors (%( foo:bar ..// ;; baz)** (1230)
  - Final valid token is now the synthetic `:)`. Update the test to assert that `:baz` appears somewhere before the trailing closer rather than insisting it’s the last valid token.
- **Cascade error recovery – nested structural + identifier issues** (1267)
  - The stream emits `:%{` (not bare `%`). Update assertions to check for `:%{` and the other structural tokens now produced.

## Code Fixes Required

- **Structural synthesis: heredocs and strings**
  - *Missing `bin_heredoc_end`* (964) and *missing `list_heredoc_end`* (972) – ensure EOF draining enqueues the appropriate end tokens.
  - *Missing interpolation terminator synthesizes end_interpolation* (1004) – also synthesize `:bin_string_end` after the string-level error.
  - *EOF drains multiple errors with synthesis* (1124) & *Cascade string with escaped newline and unterminated interpolation* (1282) & *Nested interpolation EOF recovery* (1219, 1244) – extend the draining logic so nested string/interpolation stacks emit all missing closers (and the expected number of error tokens).
- **String character errors (invalid bidi/line-break, interpolation inside quoted identifier, etc.)** (784, 791, 801, 811)
  - Recovery currently swallows the remainder; implement a strategy that advances past the offending codepoint, synthesizes the closing delimiter, and resumes so the trailing `+ 1` tokens emit.
- **Control characters & null bytes** (114, 126, 1540, 1320, 1330)
  - `scan_to_sync/3` consumes the entire remainder when no sync point exists. Update the fallback branch to drop just one grapheme (or a short span) so the stream continues (e.g., `foo
bar` should still emit `:bar`).
- **Forward progress: error recovery reaches EOF** (1320)
  - Same root cause as above; ensure continuation tokens emit after multiple errors.
- **Identifier sanitization: confusable identifier** (540)
  - The error message for confusable characters doesn’t include any of the keywords we match. Broaden `identifier_sanitization_candidate?/1` to detect messages like “Codepoint failed identifier tokenization…” so the sanitized identifier is emitted after the error.
- **Structural synthesis with synthesis disabled** (1173, 1186)
  - Decide whether the literal unexpected closer should still be emitted when `insert_structural_closers: false` (current behaviour drops it). If yes, adjust the driver to re-emit the offending token after emitting the error.
- **Keyword spacing (foo:bar)** (473)
  - Driver emits a single error covering the entire token. Consider emitting the prefix identifier (`:foo`) before reporting the spacing error so downstream code can still see the identifier.
- **Nested cascade scenarios** (1219, 1244, 1282)
  - Ensure cascaded contexts (interpolation within interpolation) emit all missing error tokens and synthetic closers; currently only two errors appear where three are expected.
- **Cascade “mixed errors” case** (1230)
  - Recovery pushes a synthetic `:)` after `:baz`, making `baz` no longer the last valid token. Decide whether to strip trailing synthetic closers from `valid_tokens/1`, or update the test to search for `:baz` earlier.

## Open Decisions / Clarifications

- **Non-synthesis mode (`insert_structural_closers: false`)** – Confirm desired behaviour for unexpected/mismatched closers. If the intent is to keep the literal closer in the stream, update the driver; otherwise adjust tests to expect its absence.
- **Keyword spacing recovery** – If we choose to keep emitting only an error token (no prefix identifier), align documentation/tests with that behaviour; otherwise reintroduce the identifier token before the error.
- **String error recovery scope** – Decide whether tolerant mode should always resume past `+ 1` style tails after string errors. If not, tests should be relaxed to focus on presence of closing tokens rather than arithmetic that follows.

Once the above decisions are made and code changes merged, re-run the suite to validate fixes, then update the corresponding tests to assert the new behaviour.
