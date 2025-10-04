# Test Fix Plan - Claude Analysis

**Date**: 2025-10-04
**Test Suite**: test/toxic_tolerant_mode_test.exs
**Total Failures**: 37 out of 131 tests

---

## Executive Summary

After analyzing all 37 test failures, I've identified the following categories:

1. **Opener synthesis ordering (CRITICAL)** - 3 tests
2. **Closer synthesis missing** - 6 tests
3. **EOL token emission** - 6 tests
4. **Identifier sanitization not emitting sanitized identifier** - 2 tests
5. **Continuation after errors** - 8 tests
6. **Multiple errors in sequence** - 4 tests
7. **String/interpolation errors** - 5 tests
8. **Synthesis vs non-synthesis mode** - 3 tests

### Key Findings

**Most tests appear to have CORRECT expectations**. The implementation has bugs, not the tests.

---

## Category 1: Opener Synthesis Ordering (CRITICAL)

### Test #29: "unexpected closer ) synthesizes opening ("
**Line**: 1051
**Status**: ❌ FAILING
**Expected**: `[:error_token, :"(", :")"]` (error first, then synthetic opener, then actual closer)
**Actual**: `[:"(", :error_token, :")"]` (synthetic opener first!)

**Root Cause**: Line 1017 in driver.ex puts opener in `pre_synth` which comes BEFORE error.

**Test Expectation**: ✅ CORRECT (per TOLERANT_FINISH_PLAN.md line 12)

**Fix Required**: Change line 1017 from `{inserted_struct, []}` to `{[], inserted_struct}` to put opener in `post_synth`.

### Test #36: "synthetic tokens have zero-length spans"
**Line**: 1199
**Status**: ❌ FAILING
**Issue**: Cannot find synthetic ( after error because it's BEFORE error

**Test Expectation**: ✅ CORRECT - expects synthetic token at `error_idx + 1`

**Fix**: Same as Test #29

### Test #10: "unexpected closer without synthesis has no synthetic opener"
**Line**: 1173
**Status**: ❌ FAILING
**Expected**: `[:error_token, :")"]` (no synthesis when `insert_structural_closers: false`)
**Actual**: `[:error_token]` (missing actual closer!)

**Root Cause**: The actual `)` is consumed during error recovery but not emitted.

**Test Expectation**: ✅ CORRECT

**Fix Required**: When synthesis is disabled, must still emit the actual closer token that caused the error.

---

## Category 2: Closer Synthesis Missing

### Test #6: "missing quoted atom terminator synthesizes atom_safe_end"
**Line**: 988
**Input**: `":foo`
**Expected**: `:atom_safe_end` synthesized at EOF
**Actual**: `[:atom_unsafe_start, :string_fragment, :error_token, :atom_unsafe_end]`

**Analysis**: Already emits `:atom_unsafe_end` (not `:atom_safe_end`). This might be a test expectation error OR the synthesized token type is wrong.

**Test Expectation**: ⚠️ QUESTIONABLE - need to check if `:atom_safe_end` vs `:atom_unsafe_end` matters

### Test #8: "missing interpolation terminator synthesizes end_interpolation"
**Line**: 1004
**Input**: `"#{x`
**Expected**: `:bin_string_end` after synthesis
**Actual**: `[:bin_string_start, :begin_interpolation, :identifier, :error_token, :end_interpolation]`

**Analysis**: Synthesizes `:end_interpolation` but NOT `:bin_string_end`. Missing outer string terminator.

**Test Expectation**: ✅ CORRECT - should synthesize BOTH closers (inner and outer)

**Fix Required**: EOF draining must synthesize ALL missing terminators from scope stack, not just innermost.

### Test #5: "missing heredoc terminator synthesizes bin_heredoc_end"
**Line**: 964
**Status**: ❌ Same issue as #8

### Test #11: "missing list heredoc terminator synthesizes list_heredoc_end"
**Line**: 972
**Status**: ❌ Same issue as #8

### Test #24: "EOF drains multiple errors with synthesis"
**Line**: 1124
**Input**: `"#{foo("`
**Expected**: `:identifier` for `foo` in output
**Actual**: `[:bin_string_start, :begin_interpolation, :paren_identifier, :"(", :error_token, :end_interpolation, :error_token, :")"]`

**Analysis**: `foo` is emitted as `:paren_identifier` (function call form), not plain `:identifier`

**Test Expectation**: ⚠️ QUESTIONABLE - `:paren_identifier` is valid for `foo(...)`, test might need adjustment

### Test #15: "mismatched closer without synthesis has no synthetic expected"
**Line**: 1186
**Input**: `([)`
**Expected**: NO `)` in output (consumed by error, not synthesized)
**Actual**: `[:"(", :"[", :error_token, :error_token, :error_token]` (NO `)`)

**Analysis**: Test expects `)` to be present! But it's consumed by error.

**Test Expectation**: ❌ WRONG - Test line 1193 `assert :")" in types` but input `([)` means `)` is the ERROR, should be consumed. Comment says "actual consumed by error" but assertion contradicts this.

---

## Category 3: EOL Token Emission

### Test #1: "backslash newline at EOF"
**Line**: 215
**Input**: `"x\\\n"`
**Expected**: `[:identifier, :error_token]`
**Actual**: `[:identifier, :error_token, :eol]`

**Analysis**: EOL is being emitted after the error. The `\n` is part of the error (invalid escape at EOF).

**Test Expectation**: ✅ CORRECT - EOL should NOT be emitted when it's part of an error

**Fix Required**: Error recovery must consume the newline when it's part of the error context (e.g., `\<newline>` at EOF).

### Similar tests: #16, #30, #3, #4
All have the same pattern: Extra `:eol` in output after error.

---

## Category 4: Identifier Sanitization

### Test #17: "confusable identifier is sanitized"
**Line**: 540
**Input**: `"foO<confusable> + 1"`
**Expected**: `[:error_token, :identifier, :dual_op, :int, ...]`
**Actual**: `[:error_token, :dual_op, :int]` (NO identifier!)

**Analysis**: Sanitized identifier not being emitted at all!

**Test Expectation**: ✅ CORRECT

**Fix Required**: `adjust_recovery` must emit sanitized identifier as a token in `recovery_tokens`. Currently only computes it but doesn't insert it.

### Test #20: "keyword not followed by space"
**Line**: 473
**Input**: `"do:something"`
**Expected**: `[:identifier, :error_token, :identifier, :dual_op, :identifier, ...]`
**Actual**: `[:error_token, :dual_op, :identifier]`

**Analysis**: Similar issue - missing tokens before error.

**Test Expectation**: ✅ CORRECT

**Fix Required**: When `do:` is parsed, `do` should be emitted as identifier before error.

---

## Category 5: Continuation After Errors

### Test #23: "control char carriage return with continuation"
**Line**: 114
**Input**: `"x\ry"`
**Expected**: `[:identifier, :error_token, :identifier]`
**Actual**: `[:identifier, :error_token]` (missing second identifier!)

**Analysis**: After error, tokenization doesn't continue to parse `y`.

**Test Expectation**: ✅ CORRECT

**Fix Required**: Error recovery must continue tokenizing after sync point. The `\r` is an error, but `y` should still be tokenized.

### Similar: Test #2 (alias error), Test #35 (mismatched delimiter continuation)

---

## Category 6: Multiple Errors in Sequence

### Test #28: "multiple invalid chars in sequence"
**Line**: 126
**Input**: Has 2 invalid characters
**Expected**: 2 error tokens
**Actual**: 1 error token

**Analysis**: Multiple consecutive invalid characters are being merged into a single error.

**Test Expectation**: ✅ CORRECT - Each invalid character should produce its own error

**Fix Required**: Error recovery must not skip over additional errors when advancing.

### Similar: Test #7, #27

---

## Category 7: String/Interpolation Errors

### Test #5, #21, #26, #37: Invalid characters in strings
**Expected**: `:int` token (probably from interpolation like `#{123}`)
**Actual**: No `:int` token

**Analysis**: Test inputs need investigation - might be test data issues.

**Test Expectation**: ⚠️ NEEDS INVESTIGATION

---

## Category 8: Cascade/Complex Errors

### Test #13: "nested structural + identifier issues"
**Line**: 1267
**Expected**: `:%` token in output
**Actual**: `[:%{}, :"{", ...]`

**Analysis**: `:%{}` is the map token, test expects bare `:%`.

**Test Expectation**: ❌ WRONG - `:%{}` is correct token for map literal

---

## Priority Fix Order

### P0 - Critical (Blocks Many Tests)
1. **Opener synthesis ordering** (Tests #29, #36)
   - Fix: Change driver.ex:1017 to put openers in `post_synth`
   - Impact: 3 tests

2. **Actual closer emission when synthesis disabled** (Test #10)
   - Fix: Emit the actual closer token even when not synthesizing
   - Impact: 1 test

3. **Identifier sanitization emission** (Tests #17, #20)
   - Fix: Add sanitized identifier to `recovery_tokens` in `adjust_recovery`
   - Impact: 2 tests

### P1 - High Priority
4. **EOL emission in error context** (Tests #1, #16, #30, #3, #4, #3)
   - Fix: Don't emit EOL when it's part of error context
   - Impact: 6 tests

5. **Continuation after errors** (Tests #23, #2, #35)
   - Fix: Ensure tokenization continues after sync point
   - Impact: 8 tests

6. **Multiple errors in sequence** (Tests #28, #7, #27)
   - Fix: Don't merge consecutive errors
   - Impact: 4 tests

### P2 - Medium Priority
7. **EOF draining all terminators** (Tests #8, #5, #11, #24)
   - Fix: Drain entire scope stack at EOF, not just innermost
   - Impact: 4 tests

8. **String/interpolation investigations** (Tests #5, #21, #26, #37)
   - Requires investigation of test data
   - Impact: 5 tests

### P3 - Test Fixes Needed
9. **Fix incorrect test expectations**
   - Test #15: Remove assertion for `)`
   - Test #13: Change to expect `:%{}`
   - Impact: 2 tests

---

## Implementation Strategy

### Phase 1: Quick Wins (30 min)
- Fix opener synthesis ordering (P0.1)
- Fix identifier sanitization emission (P0.3)
- **Expected improvement**: ~5 tests pass

### Phase 2: Error Recovery (1-2 hours)
- Fix EOL emission (P1.4)
- Fix continuation after errors (P1.5)
- Fix actual closer emission (P0.2)
- **Expected improvement**: ~15 tests pass

### Phase 3: Complex Cases (2-3 hours)
- Fix multiple errors (P1.6)
- Fix EOF draining (P2.7)
- **Expected improvement**: ~8 tests pass

### Phase 4: Investigation & Cleanup (1 hour)
- Investigate string tests (P2.8)
- Fix test expectations (P3.9)
- **Expected improvement**: ~7 tests pass

---

## Test Expectation Summary

| Category | Correct | Wrong | Questionable | Total |
|----------|---------|-------|--------------|-------|
| Opener synthesis | 3 | 0 | 0 | 3 |
| Closer synthesis | 3 | 1 | 2 | 6 |
| EOL emission | 6 | 0 | 0 | 6 |
| Identifier sanitization | 2 | 0 | 0 | 2 |
| Continuation | 8 | 0 | 0 | 8 |
| Multiple errors | 4 | 0 | 0 | 4 |
| String/interpolation | 0 | 0 | 5 | 5 |
| Complex | 0 | 2 | 0 | 2 |
| **TOTAL** | **26** | **3** | **7** | **37** |

**Conclusion**: ~70% of test expectations are definitely correct. ~8% are definitely wrong. ~19% need investigation.

---

**Analysis Date**: 2025-10-04
**Analyst**: Claude Code
**Next Action**: Implement P0 fixes first, starting with opener synthesis ordering
