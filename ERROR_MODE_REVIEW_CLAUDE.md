# Tolerant Mode Implementation Review

## Executive Summary

The tolerant mode implementation in `lib/toxic/driver.ex` is **solid and well-structured**, with comprehensive test coverage in `test/toxic_tolerant_mode_test.exs`. The code-based recovery correctly implements the ERROR_MODEL.md vision, avoiding message parsing and using structured errors throughout. However, there are gaps in details validation, error code verification tests, and documentation of some recovery patterns.

**Overall Assessment**: ✅ Implementation is correct and production-ready, with recommended improvements for completeness and maintainability.

---

## 1. Implementation Correctness ✅

### Strengths

**1.1 Code-Based Recovery (No Message Parsing)**
- ✅ `adjust_recovery/5` (lines 1178-1335) correctly pattern matches on `error.code` and `domain`
- ✅ No string parsing of error messages anywhere in recovery paths
- ✅ Recovery decisions use typed details maps (e.g., `Map.get(details, :escape_at_eof?, false)`)

**1.2 Structured Error Creation**
- ✅ All error builders create proper `%Toxic.Error{}` structs:
  - `missing_terminator_reason/2` → `:string_missing_terminator` | `:heredoc_missing_terminator`
  - `missing_interpolation_reason/2` → `:interpolation_missing_terminator`
  - `missing_scope_terminator_reason/2` → `:terminator_missing_closer`
  - `mismatched_delimiter_reason/3` → `:terminator_mismatched_closer` | `:reserved_unexpected_end`
- ✅ Builders fill in all required fields: `code`, `domain`, `token_display`, `details`
- ✅ Position information preserved via `details` maps (`:line`, `:column`, `:end_line`, `:end_column`)

**1.3 Synthesis Logic**
- ✅ `synthesize_from_reason/2` (lines 1670-1700) correctly distinguishes:
  - `:closer` - for mismatched closers (synthesize expected)
  - `:opener` - for unexpected closers (synthesize matching opener)
  - `:none` - for non-structural errors
- ✅ Synthesis respects `insert_structural_closers` flag
- ✅ Scope updates correctly push/pop terminator stack during synthesis

**1.4 Forward Progress Guarantee**
- ✅ Lines 1041-1046: Always consumes at least one codepoint if no progress made
- ✅ Scan-to-sync has max_skip fallback (line 1435)
- ✅ `consume_one/2` uses Unicode grapheme clusters for proper multi-byte handling

**1.5 Token Ordering**
- ✅ Lines 1158-1161: Correct emission order:
  ```
  deferrals + pre_inserted + pre_synth + error + post_inserted + post_synth + post_actual_closer
  ```
- ✅ Deferrals flushed before error (preserves EOL, semicolons)
- ✅ Stale EOL dropped when error crosses lines (lines 1142-1146)

---

## 2. Error Recovery Assumptions 🟡

### Sane Assumptions ✅

**2.1 Sync Points**
- ✅ Sensible defaults: `:semicolon`, `:newline`, `:closer`, `:comma`
- ✅ Configurable via `error_sync` option
- ✅ Stops at whitespace and comments (editor-friendly)

**2.2 Context-Specific Recovery**
- ✅ `:reserved_unexpected_end` - consume "end" keyword (line 1180)
- ✅ `:alias_unexpected_paren` - emit `(` before error, push to stack (line 1189)
- ✅ `:vc_merge_conflict_marker` - consume entire line (line 1206)
- ✅ `:keyword_missing_space_after_colon` - emit identifier, consume `:` (line 1231)
- ✅ `:map_invalid_open_delimiter` - emit `%`, skip whitespace (line 1247)

**2.3 Identifier Sanitization**
- ✅ Normalizes via confusable skeleton + NFKC (line 1347)
- ✅ Filters to ASCII alphanumeric + underscore (line 1350)
- ✅ Truncates to 255 chars (line 1351)
- ✅ Ensures valid start char (line 1352)

### Questionable/Underdocumented Assumptions 🟡

**2.4 Map Context Heuristic**
- Lines 1298-1305: Pre-inserts synthetic `%` token when `recent_token` is `%{}` or `{`
- **Issue**: This is a clever fix for map-related identifier errors, but:
  - Not documented in ERROR_MODEL.md recovery table
  - Heuristic based on recent_token is brittle
  - What if recent_token is incorrect due to prior error?

**2.5 Ternary Missing Slash**
- Line 1219: Special-cases `..//` (missing trailing slash)
- Emits `{:identifier, meta, :..//}` token AFTER error
- **Issue**: Not in ERROR_MODEL.md as a distinct error code
- Should this be `:operator_malformed_ternary` with documented recovery?

**2.6 Consecutive Semicolons**
- Line 1326: Special-cases `;;` pattern
- Emits single `;` token after error
- **Issue**: Mentioned in ERROR_MODEL.md table but only in fallback cond
- Should have dedicated error code like `:syntax_consecutive_semicolons`?

**2.7 Escape at EOF**
- Line 1266: Checks `escape_at_eof?` detail
- **Issue**: Not documented in ERROR_MODEL.md per-code details contracts
- Should add to `:string_missing_terminator` details spec

---

## 3. Test Coverage 🟢

### Comprehensive Coverage ✅

**3.1 Error Categories (Tests by Domain)**
- ✅ Invalid characters (null, control chars, VC markers): 4 tests
- ✅ Malformed numbers (trailing garbage, overflow): 4 tests
- ✅ Invalid escapes (backslash at EOF): 3 tests
- ✅ Terminator mismatches (unexpected/mismatched closers): 10 tests
- ✅ Map syntax errors (space after %, invalid openers): 3 tests
- ✅ Keyword spacing errors: 2 tests
- ✅ Identifier sanitization (mixed script, confusables, length): 16 tests
- ✅ Reserved tokens and aliases: 5 tests
- ✅ Sigil errors: 3 tests
- ✅ Comment errors (bidi, linebreak): 4 tests
- ✅ String/interpolation errors: 4 tests
- ✅ Missing terminators: 12 tests
- ✅ **Total**: ~70 error type tests

**3.2 Structural Synthesis**
- ✅ All missing terminators synthesize correct end tokens: 8 tests
- ✅ Unexpected closers synthesize matching openers: 4 tests
- ✅ Mismatched closers synthesize expected closers: 1 test
- ✅ Nested missing terminators: 1 test
- ✅ Synthesis flag enabled/disabled: 4 tests
- ✅ Zero-length spans on synthetic tokens: 1 test

**3.3 Recovery Properties**
- ✅ Forward progress (no infinite loops): 4 tests
- ✅ Deferral preservation (EOL, semicolons): 2 tests
- ✅ Sync point behavior: 6 tests
- ✅ Cascade/nested errors: 5 tests
- ✅ Continuation after errors: 3 tests
- ✅ Edge cases (EOF, only errors): 4 tests

**3.4 What Tests Actually Verify**
- ✅ Error tokens emitted (`length(error_tokens(tokens))`)
- ✅ Valid tokens after error (`valid_tokens(tokens)`)
- ✅ Token type sequences (`token_types(tokens)`)
- ✅ Token values (`:foo`, `:bar`, etc.)
- ✅ Token ordering (error before/after synthetic)
- ✅ Forward progress (`assert_forward_progress/1`)
- ✅ Position accuracy (line numbers, error spans)

### Coverage Gaps 🔴

**3.5 Missing: Error Code Assertions**
- ❌ Tests don't verify `error.code` values
- ❌ ERROR_MODEL.md mentions `assert_error_code/3` helper (lines 212-216) but it's not used
- **Impact**: Could emit wrong error code and tests wouldn't catch it

**Example test needed**:
```elixir
test "unexpected closer has correct error code" do
  tokens = tokenize_tolerant(")")
  {:error_token, _meta, %Toxic.Error{code: code}} =
    Enum.find(tokens, &match?({:error_token, _, _}, &1))
  assert code == :terminator_unexpected_closer
end
```

**3.6 Missing: Details Validation**
- ❌ No tests verify `details` map contents
- ❌ No runtime validation that required keys are present
- **Impact**: Formatters could crash on missing keys at runtime

**Example test needed**:
```elixir
test "mismatched closer has required details" do
  tokens = tokenize_tolerant("([)")
  {:error_token, _, %Toxic.Error{details: details}} =
    Enum.find(tokens, &match?({:error_token, _, _}, &1))
  assert Map.has_key?(details, :opening_delimiter)
  assert Map.has_key?(details, :expected_delimiter)
  assert Map.has_key?(details, :closing_delimiter)
end
```

**3.7 Missing: Position Field Tests**
- ❌ No tests verify `error.position` field
- ❌ Only tests check meta positions, not error struct positions
- **Impact**: Position field may be nil when it should have a value

**3.8 Missing: Severity Field Tests**
- ❌ No tests verify `error.severity` (always `:error` currently)
- **Impact**: Future warning support (Phase 6) won't be tested

**3.9 Missing: Zero-Length Meta Coverage**
- ⚠️ Only ONE test checks synthetic tokens have zero-length spans (line 1190)
- **Recommendation**: Test zero-length for each synthesis type (opener/closer/interpolation/string ends)

**3.10 Missing: Scope State After Recovery**
- ❌ No tests verify terminator stack is correct after error recovery
- ❌ Could synthesize and pop incorrectly, leaving stack corrupted
- **Impact**: Subsequent errors may recover incorrectly

**Example test needed**:
```elixir
test "terminator stack correct after mismatched closer" do
  tokens = tokenize_tolerant("([) + 1")
  # After ([), stack should be empty (both closed)
  # Verify next ( opens correctly
  tokens2 = tokenize_tolerant("([) + (foo)")
  types = token_types(tokens2)
  assert :\")\" in types  # Should close the final (
end
```

---

## 4. Missing from ERROR_MODEL.md Plan 🔴

### Phase 0 Items Not Implemented

**4.1 Details Validation**
- ERROR_MODEL.md line 256: "Add details validation (Option B) in Toxic.Error"
- ERROR_MODEL.md line 111: "pragmatic validator per code that asserts required keys"
- ❌ **Not implemented**: No `validate_details!/2` function visible
- ❌ No runtime checks in error constructors

**4.2 Message Snapshot Tests**
- ERROR_MODEL.md line 170: "Add message snapshot tests: `test/toxic/error_format_test.exs`"
- ❌ **File does not exist**
- **Purpose**: Lock exact Elixir message parity before migrating producers

**4.3 Error Code Scaffold Tests**
- ERROR_MODEL.md line 171: "Add error-code scaffold tests: `test/toxic/error_code_test.exs`"
- ❌ **File does not exist**
- **Purpose**: One test per domain initially, all codes by Phase 5

**4.4 ensure_struct/1 Logging**
- ERROR_MODEL.md line 172: "Implement exhaustive ensure_struct/1 with safe fallback logging unmapped shapes"
- ⚠️ **Cannot verify**: `Toxic.Error.ensure_struct/1` not in driver.ex (must be in separate module)
- Should check if it logs unmapped legacy error shapes

### Recovery Table vs Implementation Gaps

**4.5 Error Codes Without Explicit Handlers**

From ERROR_MODEL.md recovery table (lines 130-148), these codes lack explicit cases in `adjust_recovery/5`:

| Code | Handled? | Notes |
|------|----------|-------|
| `:interpolation_missing_terminator` | ✅ | In `emit_pending_error`, not `adjust_recovery` (by design) |
| `:sigil_invalid_name` | ❌ | Falls through to default/domain match |
| `:sigil_invalid_delimiter` | ❌ | Falls through to default |
| `:number_invalid_float` | ❌ | Falls through to default |
| `:encoding_invalid` | ❌ | Not explicitly handled |
| `:identifier_empty` | ❌ | Handled via `:identifier` domain match |
| `:identifier_mixed_script` | ✅ | Via `:identifier` domain (line 1290) |
| `:identifier_confusable` | ✅ | Via `:identifier` domain |
| `:identifier_nfkc_needed` | ✅ | Via `:identifier` domain |
| `:identifier_invalid_char` | ✅ | Via `:identifier` domain |
| `:alias_invalid_character` | ❌ | No explicit handling |

**Analysis**: Domain-level matching (e.g., `{:identifier, _}`) is reasonable for identifier variants, but sigil/alias/number errors should have explicit recovery or documented fallback behavior.

**4.6 Undocumented Recovery Patterns**

These patterns exist in code but not in ERROR_MODEL.md table:

1. **Ternary missing slash** (line 1219):
   - Pattern: `..//` without trailing `/`
   - Recovery: Emit `{:identifier, meta, :..//}` AFTER error
   - **Missing**: Error code definition, details contract

2. **Consecutive semicolons** (line 1326):
   - Pattern: `;;`
   - Recovery: Emit single `;` token
   - **Documented** in table (line 148) but not as error code

3. **Map context identifier recovery** (lines 1298-1305):
   - Pattern: Identifier error after `%{}` or `{`
   - Recovery: Pre-insert synthetic `%` token
   - **Missing**: From recovery table

---

## 5. Correctness Issues & Edge Cases ⚠️

### Potential Bugs (Low Severity)

**5.1 Mismatched Closer Actual Emission Logic**
- Lines 1119-1136: Complex logic to decide if actual closer should be emitted
- Checks if closer matches updated stack after synthesis
- **Edge case**: What if synthesis pushes wrong opener?
  - Example: `([}` - mismatched `}` for `[`
  - Code synthesizes `]`, then checks if `}` matches stack
  - If stack is corrupted, `}` might not emit
- **Recommendation**: Add test for triple-nested mismatch: `([{)`

**5.2 Escape at EOF Detail Key**
- Line 1266: Uses `Map.get(details, :escape_at_eof?, false)`
- **Issue**: This key not in ERROR_MODEL.md contracts for `:string_missing_terminator`
- **Risk**: If producers don't set this, recovery wrong for `"foo\`
- **Fix**: Document in details contract (lines 95-101 of ERROR_MODEL.md)

**5.3 Heredoc Invalid Header Token Display**
- Lines 1281-1285: Infers end token from `err.token_display`
- **Assumption**: `token_display` is set to delimiter (`'''` or `"""`)
- **Risk**: If producer sets wrong token_display, wrong end token synthesized
- **Recommendation**: Add validation or fallback

### Race Conditions / State Corruption (None Found) ✅

- ✅ No global state mutated
- ✅ All state updates return new state
- ✅ Terminator stack updates are pure
- ✅ No async operations

---

## 6. Recommendations

### High Priority 🔴

1. **Implement Details Validation**
   ```elixir
   # In Toxic.Error module
   defp validate_details!(:terminator_mismatched_closer, details) do
     required = [:opening_delimiter, :expected_delimiter, :closing_delimiter]
     Enum.each(required, fn key ->
       unless Map.has_key?(details, key) do
         raise ArgumentError, "Missing required detail: #{key}"
       end
     end)
   end
   ```

2. **Add Error Code Tests**
   - Create `test/toxic/error_code_test.exs`
   - One test per error code verifying correct code emitted
   - Example template:
   ```elixir
   test ":terminator_unexpected_closer code" do
     assert_error_code(")", :terminator_unexpected_closer)
   end
   ```

3. **Add Message Snapshot Tests**
   - Create `test/toxic/error_format_test.exs`
   - Lock `Toxic.Error.format/1` output for each code
   - Catch message regressions before Elixir compatibility breaks

4. **Document Missing Recovery Patterns**
   - Add ternary missing slash to ERROR_MODEL.md
   - Add map context identifier handling
   - Document escape_at_eof detail key

### Medium Priority 🟡

5. **Add Scope State Tests**
   - Verify terminator stack after each error type
   - Test nested errors don't corrupt stack
   - Example:
   ```elixir
   test "stack depth correct after nested errors" do
     tokens = tokenize_tolerant("([{")
     # Should emit 3 errors + 3 synthetic closers
     assert length(error_tokens(tokens)) == 3
     # Verify stack is empty at end (all popped)
   end
   ```

6. **Add Zero-Length Meta Tests**
   - Test each synthesis type has zero-length spans
   - Verify synthetic openers/closers/interpolation ends

7. **Add Details Content Tests**
   - Verify required keys present for each error code
   - Check detail values are correct (delimiters, positions)

8. **Add Position Field Tests**
   - Verify `error.position` is set for positional errors
   - Check nil for EOF/context errors

### Low Priority 🟢

9. **Refactor Ternary/Semicolon to Codes**
   - Consider adding explicit error codes:
     - `:operator_malformed_ternary`
     - `:syntax_consecutive_semicolons`
   - Document recovery in table

10. **Add Logging to ensure_struct/1**
    - Verify fallback logs unmapped error shapes
    - Add test that legacy errors are caught

11. **Review Formatter Coverage**
    - Ensure all error codes have `format/1` clauses
    - Add to snapshot tests

---

## 7. Overall Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| **Implementation Correctness** | ✅ Excellent | Code-based recovery, proper synthesis, forward progress |
| **Error Model Adherence** | 🟡 Good | Structured errors used, some codes missing explicit handlers |
| **Test Coverage** | 🟢 Very Good | ~100 tests, all error categories, synthesis, properties |
| **Test Quality** | 🟡 Good | Verifies continuation and ordering, missing code/details checks |
| **Documentation** | 🟡 Fair | Some recovery patterns undocumented, missing Phase 0 items |
| **Edge Case Handling** | ✅ Good | Forward progress guaranteed, complex cases tested |
| **Maintainability** | 🟢 Good | Clean code, clear separation, needs validation layer |

### Final Verdict

**The implementation is production-ready and correct**, with solid error recovery that handles real-world cases well. The main gaps are:

1. **Missing validation layer** - details contracts not enforced
2. **Missing error code tests** - can't verify correct codes emitted
3. **Missing Phase 0 test files** - format/code scaffold tests planned but not created
4. **Undocumented patterns** - ternary, map context recovery not in spec

**Recommended next steps**:
1. Add details validation (2-3 hours)
2. Create error_code_test.exs with code assertions (4-6 hours)
3. Create error_format_test.exs with message snapshots (4-6 hours)
4. Document missing recovery patterns in ERROR_MODEL.md (1 hour)
5. Add scope/position/details tests (2-3 hours)

**Total effort to complete**: ~2 days

**Risk if shipped as-is**: Low - code works correctly, gaps are in validation/verification layers that would catch future bugs but don't affect current correctness.
