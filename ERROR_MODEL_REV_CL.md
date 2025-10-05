## Review of Phases 0-4 Implementation

### Executive Summary

**Status**: **Phases 0-1 Substantially Complete; Phases 2-4 Incomplete**

The core infrastructure (`Toxic.Error` module, Driver integration, and test scaffolding) has been implemented. However, **leaf error producers** (String, Interpolation, Sigil, Terminator, Tokenizer subsystems) still emit legacy error tuples/atoms, causing widespread test failures.

**Test Results**:
- Strict mode: **66/67 failures** (98% failure rate)
- Tolerant mode: **55/131 failures** (42% failure rate)

---

### Phase 0 – Scaffolding: ✅ **COMPLETE**

#### Implemented ✓
1. **`Toxic.Error` module** (`lib/toxic/error.ex`):
   - Full struct definition with 40+ error codes
   - `@enforce_keys [:code]` ensures minimum validity
   - Domain inference via `infer_domain/1` (all codes covered)
   - `format/1` API with Elixir-compatible message formatting (13 codes implemented, fallback for others)
   - `to_reason_tuple/1` with legacy meta keyword construction
   - `ensure_struct/1` bridge supporting:
     - `%Toxic.Error{}` passthrough
     - `{meta_kw, message, token_chars}` tuple conversion with code inference
     - Atom-based legacy errors (e.g., `:vc_marker` → `:vc_merge_conflict_marker`)
     - Fallback for unknown shapes with `details: %{legacy: term}`

2. **Test scaffolding**:
   - `test/toxic/error_format_test.exs`: 2 snapshot tests (both `@tag :skip`)
   - `test/toxic/error_code_test.exs`: 1 tolerant-mode test (skipped)

#### Missing / Gaps
1. **`details` validation** (Plan: "Option B pragmatic validators"):
   - Not implemented; no `validate_details/2` calls in `Toxic.Error.new/1` or struct creation
   - Risk: Invalid details keys will fail silently during pattern matching in `adjust_recovery/5`

2. **Message snapshot coverage**:
   - Only 13/40+ codes have `format/1` clauses; remaining fall back to `"syntax error"`
   - Missing formatters for:
     - All identifier codes (`:identifier_mixed_script`, `:identifier_confusable`, etc.)
     - String/heredoc terminators (`:string_missing_terminator`, `:heredoc_missing_terminator`)
     - Sigil errors
     - Encoding/comment/VC errors
   - **Impact**: Strict tests fail with generic "syntax error" instead of parity messages

3. **Snapshot test activation**:
   - Both `error_format_test.exs` tests are `@tag :skip`
   - No assertion that `format/1` output matches current Driver message builders
   - Plan specified: "lock strings before migrating producers" — not done

4. **Exhaustive `ensure_struct/1` patterns**:
   - Current implementation handles main cases but lacks:
     - Explicit logging for fallback path (plan said "temporary warning log")
     - Unit tests covering all legacy shapes from ERRORS.md (no dedicated test file)

---

### Phase 1 – Driver Adoption: ⚠️ **PARTIALLY COMPLETE**

#### Implemented ✓
1. **Driver reason builders emit structs**:
   - `missing_terminator_reason/2` → `%Toxic.Error{code: :string_missing_terminator | :heredoc_missing_terminator}`
   - `missing_interpolation_reason/2` → `%Toxic.Error{code: :interpolation_missing_terminator}`
   - `missing_scope_terminator_reason/2` → `%Toxic.Error{code: :terminator_missing_closer}`
   - `mismatched_delimiter_reason/3` → `%Toxic.Error{code: :terminator_mismatched_closer}`
   - `interpolation_in_quoted_identifier_reason/3` → `%Toxic.Error{code: :interpolation_not_allowed_in_quoted_identifier}`

2. **Strict mode conversion** (driver.ex:102, 106, 110, 134, 187, 217, 485):
   - Calls `Toxic.Error.to_reason_tuple/1` before returning `{:error, tuple, rest, state}`
   - Uses `ensure_struct/1` bridge for non-struct errors (lines 185-186, 214-216)

3. **Tolerant mode integration**:
   - `emit_pending_error/2` wraps structs in `:error_token` (lines 927-970)
   - `emit_error_and_advance/3` converts reason to struct via `ensure_struct/1` (line 998)
   - Error tokens flow with `%Toxic.Error{}` payloads

4. **`adjust_recovery/5` adapter** (lines 1070-1147):
   - Accepts `%Toxic.Error{}` and falls back to message-based routing
   - Extracts formatted message via `Toxic.Error.format/1` + `IO.iodata_to_binary/1`
   - Still uses **all legacy heuristics** (`invalid_char_error?/1`, `escape_at_eof?/2`, `keyword_no_space?/1`, etc.)

5. **Structural synthesis updated** (lines 1611-1640):
   - `synthesize_from_reason/2` now pattern matches on `%Toxic.Error{code: ...}`
   - Handles `:terminator_mismatched_closer` explicitly (line 1611)
   - Falls back to `token_display`-based inference for unexpected closers

#### Missing / Gaps
1. **Direct code-based recovery routing**:
   - Plan: "pattern matches on `error.code` and validated `details` (no string parsing)"
   - Reality: `adjust_recovery/5` still parses formatted messages (line 1072)
   - All 15+ message-parsing helpers remain (lines 1150-1249)
   - **No pattern matching on `error.code`** in recovery logic yet

2. **Details extraction in recovery**:
   - Plan specified using `details` map directly (e.g., `details[:escape_at_eof?]`)
   - Current: `adjust_recovery` doesn't access `error.details` at all
   - Recovery decisions still based on text matching

3. **Test coverage**:
   - No new tests verifying Driver struct emission
   - No assertions that tolerant `:error_token` payloads are structs (existing tests check token kinds only)

---

### Phase 2 – String/Sigil/Heredoc/Interpolation: ❌ **NOT STARTED**

#### Expected (per plan)
- Migrate `lib/toxic/string.ex`, `lib/toxic/sigil.ex`, `lib/toxic/interpolation.ex` to emit `%Toxic.Error{}`
- Ensure details include `kind`, `delim`, `start_line`, `start_column`

#### Actual
- All three modules still return legacy shapes:
  - `lib/toxic/interpolation.ex:340`: `{:error, :bidi_formatting}`
  - `lib/toxic/string.ex:21`: `{:error, :invalid_char_after_heredoc_open}`
  - `lib/toxic/sigil.ex`: Returns atoms like `:invalid_sigil_name`, `:invalid_char_after_heredoc_open`, `:invalid_sigil_delimiter`

#### Impact
- Driver's `ensure_struct/1` converts these atoms to structs with generic `:syntax_error` code
- Message parity fails: e.g., "syntax error" instead of "invalid sigil name"
- **55 tolerant test failures** trace to this gap

---

### Phase 3 – Terminator: ❌ **NOT STARTED**

#### Expected
- Migrate `lib/toxic/terminator.ex` to emit `%Toxic.Error{code: :terminator_*}` with delimiter details

#### Actual
- `lib/toxic/terminator.ex` still returns legacy error tuples:
  - Line 7: `{:error, :unexpected_token_after_alias}` (Alias + paren)
  - Line 90: `{:error, :unexpected_token_or_reserved}` (end mismatch)
  - Line 106: `{:error, :unexpected_reserved_word}` (end without stack)
  - Line 121: `{:error, :unexpected_token_terminator}` (unmatched closers)

#### Impact
- Bridge converts atoms to structs with inferred codes (e.g., `:unexpected_token_after_alias` → `:alias_unexpected_paren`)
- Messages come from `format/1` fallback ("unexpected token: ..." or "syntax error")
- **Position metadata lost** during atom → struct conversion (no meta keyword list)

---

### Phase 4 – Tokenizer/Identifier/Number/Keyword/Alias: ❌ **NOT STARTED**

#### Expected
- Convert `lib/toxic/tokenizer.ex`, `lib/toxic/identifier.ex`, `lib/toxic/number.ex`, `lib/toxic/keyword.ex`, `lib/toxic/alias.ex` to structured errors

#### Actual
- All modules still emit legacy shapes:
  - `tokenizer.ex`: Atoms like `:vc_marker`, `:unexpected_space`, `:invalid_character`, `:reserved_token`, etc.
  - `identifier.ex`: `:mixed_script`, `:empty`
  - `number.ex`: `{:error, :invalid_float, charlist}`
  - `keyword.ex`: `{:error, :invalid_do_with_fn_error, ~c"do"}`, `{:error, :unexpected_reserved_word, ~c"do"}`
  - `alias.ex`: `{:error, :invalid_character}`

#### Impact
- Widespread strict test failures (66/67 failing)
- Most errors get generic `%Toxic.Error{code: :syntax_error}` from bridge
- Tolerant mode emits error tokens but with wrong codes/messages

---

### Phase 5 – Cleanup & Hardening: ❌ **NOT STARTED**

Plan specified:
- Remove message-parsing helpers from Driver
- Expand snapshot/code tests to 40+ codes
- Add dialyzer specs and CI check
- Centralize docs in `Toxic.Error`
- Add `TokenStream.errors/1` utility

**None of these tasks begun.**

---

## Critical Issues

### 1. **Message Parity Broken** (High Severity)
**Symptom**: 66/67 strict tests failing with position/message mismatches.

**Root Cause**:
- Leaf producers emit atoms/tuples
- Bridge converts to `%Toxic.Error{code: :syntax_error}` or inferred code
- `format/1` only implements 13/40+ codes; fallback is `"syntax error"`
- Position info lost when converting atoms (no meta keyword list available)

**Fix Required**:
1. Complete `format/1` for all 40+ codes (match Elixir messages exactly)
2. Migrate leaf producers (Phases 2-4) to emit full structs with position/details
3. Enable snapshot tests to lock messages

### 2. **Recovery Still Parses Messages** (Medium Severity)
**Symptom**: `adjust_recovery/5` still calls `parse_error_message/1` and matches text.

**Root Cause**:
- Phase 1 added struct plumbing but kept legacy routing intact
- No direct `case error.code do` branching implemented

**Fix Required**:
1. Rewrite `adjust_recovery/5` to match on `error.code` first:
   ```elixir
   defp adjust_recovery(%Toxic.Error{code: code} = err, rest, state, def_rest, def_line, def_col) do
     case code do
       :number_trailing_garbage -> consume_one(rest, state)
       :keyword_missing_space_after_colon -> {tl(rest), state.line, state.column + 1, [], state.scope}
       :map_invalid_open_delimiter -> emit_percent_and_continue(err, rest, state)
       # ... etc
       _ -> {def_rest, def_line, def_col, [], state.scope}
     end
   end
   ```
2. Remove message-parsing helpers once all producers emit structs

### 3. **Details Validation Missing** (Medium Severity)
**Symptom**: No runtime checks that required `details` keys are present.

**Risk**: Pattern matches in `adjust_recovery` (once implemented) will crash on missing keys.

**Fix Required**:
- Add validators per code in `Toxic.Error`:
  ```elixir
  defp validate_details(:terminator_mismatched_closer, details) do
    unless Map.has_key?(details, :opening_delimiter) and
           Map.has_key?(details, :expected_delimiter) do
      raise ArgumentError, "Missing required details for :terminator_mismatched_closer"
    end
  end
  ```
- Call from struct creation or `new/1` constructor

### 4. **Test Scaffolding Not Activated** (Low Severity)
**Symptom**: `error_format_test.exs` and `error_code_test.exs` have `@tag :skip`.

**Impact**: No CI protection against message regressions or code drift.

**Fix Required**:
- Remove `@tag :skip` once formatters complete and producers migrate
- Expand to full code coverage (40+ tests)

---

## Compliance with Revised Plan

| Phase | Plan Status | Actual Status | Compliance |
|-------|------------|---------------|------------|
| **Phase 0** | Scaffolding + guardrails | Struct + API complete; validators/snapshot tests incomplete | 70% |
| **Phase 1** | Driver adoption | Struct emission done; code-based recovery **not done** | 50% |
| **Phase 2** | String/Sigil/Heredoc/Interpolation | Expected | **0%** |
| **Phase 3** | Terminator | Expected | **0%** |
| **Phase 4** | Tokenizer/Identifier/Number/Keyword/Alias | Expected | **0%** |
| **Phase 5** | Cleanup & hardening | Not started | **0%** |

**Overall Compliance**: **Phase 0-1 foundation laid (~30% of total effort); Phases 2-5 not started (~70% remaining)**

---

## Strengths of Current Implementation

1. **Solid Foundation**:
   - `Toxic.Error` struct is well-designed with clear typespecs
   - `@enforce_keys [:code]` prevents invalid errors
   - `ensure_struct/1` bridge is comprehensive and handles multiple legacy shapes

2. **Driver Integration Clean**:
   - Reason builders correctly construct structs with appropriate details
   - Strict/tolerant paths cleanly separated
   - Structural synthesis already updated to use `error.code`

3. **Backward Compatible**:
   - `to_reason_tuple/1` preserves strict mode API
   - Tolerant tests remain mostly compatible (55% still passing)
   - No breaking changes to external APIs

4. **Type Safety**:
   - Full type annotations on `Toxic.Error`
   - Domain inference ensures consistency

---

## Weaknesses & Risks

1. **Premature Phase Advancement**:
   - Plan specified "lock strings before migrating producers" (Phase 0)
   - Reality: Producers not migrated yet formatters incomplete
   - **Risk**: Message drift undetected; strict tests will remain broken

2. **Incomplete Message Coverage**:
   - 13/40 codes formatted; 27 fall back to "syntax error"
   - No systematic mapping from ERRORS.md to `format/1` clauses
   - **Risk**: Parity cannot be verified until all messages implemented

3. **Bridge Overloaded**:
   - `ensure_struct/1` does heavy inference from messages/atoms
   - Position info often unavailable (atom inputs have no meta)
   - **Risk**: Tolerant recovery may synthesize incorrect tokens due to missing context

4. **No Validation**:
   - `details` map unchecked
   - Pattern matches in future code-based recovery will fail hard
   - **Risk**: Runtime crashes in tolerant mode (defeats purpose)

5. **Test Coverage Gaps**:
   - No tests asserting struct emission from Driver
   - Snapshot tests skipped
   - Error code tests skipped
   - **Risk**: Regressions undetected; migration not validated

---

## Recommended Next Steps (Priority Order)

### Critical (Blocking Progress)
1. **Complete `format/1` for all codes** (1-2 hours):
   - Extract current message text from Driver/producers
   - Add formatter clause per code in `Toxic.Error`
   - Reference ERRORS.md for exact wording

2. **Migrate String/Interpolation/Sigil (Phase 2)** (2-3 hours):
   - Update error returns to `%Toxic.Error{}` with full details
   - Preserve position info in struct
   - Ensure details include `kind`, `delim`, `start_line`, `start_column`

3. **Migrate Terminator (Phase 3)** (1-2 hours):
   - Convert 4 error sites to struct emission
   - Include delimiter details and hints

### High Priority
4. **Enable snapshot tests** (1 hour):
   - Remove `@tag :skip`
   - Add assertions for representative codes (10-15 tests)
   - Lock down message parity before proceeding

5. **Implement code-based recovery** (2-3 hours):
   - Rewrite `adjust_recovery/5` with `case error.code do`
   - Remove message-parsing heuristics
   - Use `error.details` for context

6. **Add details validation** (1 hour):
   - Per-code validators in `Toxic.Error`
   - Call from struct creation paths
   - Add unit tests

### Medium Priority
7. **Migrate Tokenizer/Identifier/Number/Keyword/Alias (Phase 4)** (3-4 hours):
   - Update 5 modules to emit structs
   - Preserve all position/context info

8. **Expand error code tests** (1 hour):
   - Remove skip tags
   - Add one test per domain (10 total)
   - Assert `error.code` and basic recovery behavior

### Low Priority (Phase 5)
9. **Remove message-parsing helpers** (30 min):
   - Delete `parse_error_message/1`, `invalid_char_error?/1`, etc.
   - Clean up unused code

10. **Add dialyzer specs + CI** (1 hour):
    - `@spec` for all `Toxic.Error` APIs
    - Enable `mix dialyzer --halt-exit-status` in CI

11. **Documentation** (30 min):
    - Add code → recovery mapping table to `Toxic.Error` module docs
    - Update ERRORS.md to reference struct as source of truth

---

## Conclusion

**The migration is 30% complete**. The core infrastructure is sound, but the majority of work remains: migrating **11 producer modules** to emit structured errors and completing **27 message formatters**. The current state is a **transitional hybrid** where Driver emits structs but all leaf producers emit atoms/tuples, causing the bridge to do heavy lifting and losing fidelity (positions, messages).

**Critical Path**:
1. Complete formatters (unlock parity)
2. Migrate String/Sigil/Interpolation (Phase 2)
3. Migrate Terminator (Phase 3)
4. Implement code-based recovery (fulfill Phase 1 promise)
5. Migrate remaining producers (Phase 4)
6. Clean up bridge and heuristics (Phase 5)

**Estimated Remaining Effort**: 12-15 hours

**Verdict**: The implementation is **on the right track** but **incomplete**. Strict tests will not pass until Phases 2-4 complete. Tolerant mode is functional but recovery is still brittle due to message parsing. Recommend prioritizing formatter completion and leaf producer migration before proceeding to cleanup.
