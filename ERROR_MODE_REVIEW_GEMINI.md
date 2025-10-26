# Review of Tolerant Mode Implementation

This document contains a review of the tolerant mode implementation based on `ERROR_MODEL.md`, `lib/toxic/driver.ex`, and `test/toxic_tolerant_mode_test.exs`.

## 1. Overall Assessment

The implementation is a significant step forward, successfully transitioning from brittle message-parsing to a robust, code-based recovery system as outlined in `ERROR_MODEL.md`. The core logic for handling errors, synthesizing tokens, and ensuring forward progress is well-established in `lib/toxic/driver.ex`. The test suite in `test/toxic_tolerant_mode_test.exs` is comprehensive and covers a wide array of error scenarios, providing good confidence in the system's resilience.

The implementation correctly captures the spirit and most of the letter of the design document. The recovery strategies are generally sane and effective. However, there are areas for improvement, primarily concerning lingering legacy logic, test clarity, and the complexity of the core error handling function.

## 2. Correctness of Implementation (`lib/toxic/driver.ex`)

The implementation in `driver.ex` is largely correct and aligns well with the design principles of `ERROR_MODEL.md`.

### Adherence to `ERROR_MODEL.md`

- **Structured Errors:** The driver correctly uses the `%Toxic.Error{}` struct, passing it within the `:error_token`.
- **Code-Based Recovery:** The central `adjust_recovery/5` function successfully uses pattern matching on `error.code` and `error.domain` for its primary logic, fulfilling a key design goal.
- **Synthesis:** Structural synthesis for terminators is implemented and correctly gated by the `insert_structural_closers` flag for unexpected closers. EOF (pending error) handling in `emit_pending_error/2` also correctly synthesizes tokens.

### Key Recovery Logic Analysis

- **`adjust_recovery/5`:** This function is the heart of the new model.
  - **Good:** It has specific, performant clauses for high-impact errors like `:reserved_unexpected_end`, `:alias_unexpected_paren`, `:keyword_missing_space_after_colon`, and `:map_invalid_open_delimiter`. The logic for identifier sanitization is also robust.
  - **Improvement:** The function still contains fallbacks to legacy pattern matching on the raw input string (`ternary_missing_slash?`, `consecutive_semicolons?`). These should be migrated to be triggered by specific error codes from the tokenizer for consistency. For example, the tokenizer should emit `:consecutive_semicolons` instead of the driver re-detecting it.

- **`emit_error_and_advance/3`:** This function is powerful but also very complex.
  - **Correctness:** The ordering of emitted tokens (`deferrals`, `pre_inserted`, `pre_synth`, `error_token`, `post_inserted`, `post_synth`, `post_actual_closer`) appears to correctly implement the desired recovery sequences from the tests. The logic to always synthesize a closer for a mismatch (`:closer -> true`) but gate the synthesis of an opener (`:opener -> state.insert_structural_closers`) is a subtle and important detail that is correctly implemented.
  - **Readability:** The sheer number of intermediate token lists makes this function difficult to trace. Adding comments to explain the purpose of each list and the final assembly order would significantly improve maintainability.

- **`synthesize_from_reason/2`:** This function correctly infers which token to synthesize based on the error code (`:terminator_mismatched_closer`) or the token display (for unexpected closers). The logic is sound.

## 3. Sanity of Recovery Assumptions

The recovery assumptions are generally very sane and contribute to a robust parsing experience.

- **Minimal Advancement:** For generic unexpected tokens, the strategy of consuming a single grapheme (`consume_one`) is a safe, minimal-progress guarantee that prevents the parser from getting stuck or skipping too much code.
- **Structural Integrity:** Synthesizing matching terminators (e.g., adding a `]` for a `(`) is an excellent strategy. It allows downstream tools (like formatters or language servers) to reason about the code's structure, even if it's invalid.
- **Identifier Sanitization:** The automatic sanitization of invalid identifiers is a powerful recovery mechanism. It prevents a single malformed identifier from halting the tokenization of the rest of the file and produces a "best-effort" token that can be useful for analysis.

## 4. Test Suite Review (`test/toxic_tolerant_mode_test.exs`)

The test suite is extensive and well-structured. It provides strong evidence that the tolerant mode is working as intended.

### Test Coverage

- **Breadth:** The coverage is excellent. The tests are categorized by error type and cover everything from simple invalid characters to complex nested terminator and interpolation issues. The inclusion of "Cascade error recovery" and "Forward progress guarantees" sections is particularly valuable.
- **Gaps:** While coverage is broad, it could be deepened with more complex interaction tests. For example:
  - A test for a mismatched closer where the *actual* closer is a valid opener for a *different* structure (e.g., `([)` where `)` is the mismatch, but what about `([<` where `<` could be a valid token?).
  - More tests combining identifier sanitization with structural errors.

### Test Quality and Correctness

- **Strengths:**
  - The `assert_forward_progress` helper is a critical piece of the test suite, ensuring the parser never gets stuck in a loop.
  - Asserting on both `token_types` and `valid_tokens` provides a good balance of checking the recovery structure and the continuation of normal tokenization.
  - The tests for structural synthesis correctly check the order of synthetic tokens relative to the error token.

- **Areas for Improvement:**
  - **Misleading Test Name:** The test `test "mismatched closer without synthesis has no synthetic expected"` is confusing. Its assertion `assert types == [:"(", :"[", :error_token, :"]", :")"]` shows that a synthetic `]` *is* produced. Based on the driver logic, this is the correct behavior (mismatches always synthesize the expected closer). The test name should be changed to reflect what it's actually testing, e.g., `"mismatched closer synthesizes expected closer even when insert_structural_closers is false"`.
  - **Assertion Clarity:** Some tests use `assert Enum.any?(...)`. While this confirms a token exists, it doesn't verify its position. For critical recovery sequences, asserting the exact `token_types` list is much stronger and proves the recovery order is correct. The terminator mismatch tests do this well, and this practice could be applied more broadly.

## 5. Missed Items & Potential Improvements

1.  **Migrate Legacy Recovery:** The `cond` block at the end of `adjust_recovery/5` should be removed. The logic for `ternary_missing_slash?` and `consecutive_semicolons?` should be handled by having the tokenizer emit specific error codes (`:ternary_missing_slash`, `:consecutive_semicolons`), which can then be handled in the main `case` statement. This would fully align the implementation with the "code-based recovery" design principle.

2.  **Clarify Synthesis Logic:** The nuanced logic for synthesis (`keep_synth` in `emit_error_and_advance/3`) is powerful but not immediately obvious. A comment explaining *why* mismatched closers are always synthesized while unexpected-closer-openers are gated by a flag would be very helpful for future maintainers.

3.  **Improve Test Naming:** As noted above, clarify the name of the test for mismatched closers when synthesis is "disabled".

4.  **Add a test for `alias_unexpected_paren` recovery:** The recovery logic for `alias_unexpected_paren` in `adjust_recovery/5` is non-trivial (it pre-inserts a `(` token and pushes to the terminator stack). There is a test named `"unexpected token after alias"` for `Foo(1+2)`, but its assertion `[:alias, :"(", :error_token, :int, :dual_op, :int, :")" | _]` seems to test a different path. A dedicated test that isolates and verifies this specific recovery mechanism is needed.
