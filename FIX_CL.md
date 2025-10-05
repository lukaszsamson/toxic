# Tolerant Mode Test Fix Plan - Claude Analysis

**Date**: 2025-10-05
**Test Suite**: test/toxic_tolerant_mode_test.exs
**Current Status**: 23 / 131 tests failing (82% pass rate)
**Previous Status**: 37 failures (from TEST_FIX_PLAN_CL.md)
**Progress**: 14 tests fixed since last analysis

---

## Executive Summary

After running the tolerant mode test suite, 23 tests are still failing. The failures fall into clear categories with identifiable root causes in `lib/toxic/driver.ex`. Most issues stem from:

1. **Greedy error recovery** consuming valid tokens that should be tokenized after errors
2. **Duplicate error emission** for unexpected closers (synthesis + actual closer both trigger errors)
3. **Missing multiple errors** for consecutive invalid characters
4. **Missing pre-error tokens** in context-specific recovery (e.g., `foo:bar` should emit `foo` first)
5. **Extra token emission** (`:end`, `:eol`) that should be suppressed after errors

---

## Test Failure Breakdown by Category

### Category A: Continuation After Errors (P0 - CRITICAL)
**Count**: 7 failures
**Pattern**: Tokenization stops or consumes valid tokens after error instead of continuing

| Test # | Line | Input | Expected | Actual | Issue |
|--------|------|-------|----------|--------|-------|
| 1 | 114 | `"x\ry"` | `[:identifier, :error_token, :identifier]` | `[:identifier, :error_token]` | Missing `y` identifier |
| 17 | 136 | `"<<<<<<< foo\nbar + baz"` | `[:error_token, :identifier, :dual_op, :identifier]` | `[:error_token, :identifier, :eol, :identifier, :dual_op, :identifier]` | Extra `:eol` |
| 5 | 1478 | `"Foo.Bär + Bar"` | Valid tokens after error | Missing `Bar` alias | Alias error consumes continuation |
| 11 | 1230 | `"% ( foo:bar ..// ;; baz"` | `{:identifier, _, :baz}` last | `{:")", ...}` last | Doesn't reach `baz` |
| 12 | 784 | `"\"\u202E\" + 1"` (bidi in string) | `:int` in output | No `:int` | String error consumes `+ 1` |
| 13 | 791 | `"\"\u2028\" + 1"` (break in string) | `:int` in output | No `:int` | String error consumes `+ 1` |
| 14 | 801 | `"'\u2028' + 1"` (break in charlist) | `:int` in output | No `:int` | String error consumes `+ 1` |
| 15 | 811 | `~S|foo."bar#{baz}"() + 1|` (interp in quoted id) | `:int` in output | No `:int` | Quoted id error consumes `+ 1` |

**Root Cause**: `scan_to_sync` fallback at line 1269-1272 in driver.ex. When `error_max_skip` is exceeded, it calls `consume_one(rest, state)` which only updates position but returns the ENTIRE remaining input as "rest after error", allowing subsequent scanning to consume everything.

### Category B: Multiple Error Tokens (P0 - CRITICAL)
**Count**: 6 failures
**Pattern**: Multiple consecutive errors produce only one error token

| Test # | Line | Input | Expected Errors | Actual Errors | Issue |
|--------|------|-------|----------------|---------------|-------|
| 7 | 126 | `"foo\0bar\0baz"` (2 nulls) | 2 | 1 | Merged into one |
| 4 | 1540 | `"a\0b\0c"` | 2 | 1 | Merged into one |
| 10 | 1320 | `"foo\0bar\0baz"` | 2 | 1 | Merged into one |
| 6 | 255 | `"} , baz"` (unexpected `}`) | 1 | 2 | Extra error |
| 8 | 248 | `"] ; bar"` (unexpected `]`) | 1 | 2 | Extra error |
| 15 | 262 | `">> + x"` (unexpected `>>`) | 1 | 2 | Extra error |
| 20 | 235 | `") + foo"` (unexpected `)`) | 1 | 2 | Extra error |

**Root Causes**:
- **Merged errors**: After `emit_error_and_advance` at line 1048-1054, the "always make progress" check prevents re-detection of the next invalid character. The second `\0` is there but isn't re-scanned.
- **Extra errors**: `post_actual_closer` logic at lines 1076-1084 emits the actual closer token after synthesis, which then gets processed by normal tokenization and triggers ANOTHER unexpected-closer error.

### Category C: Extra `:end` Token (P1)
**Count**: 1 failure
**Pattern**: Unexpected `end` emits error but also emits `:end` token

| Test # | Line | Input | Expected | Actual |
|--------|------|-------|----------|--------|
| 3 | 281 | `"end\nfoo"` | `[:error_token, :identifier]` | `[:error_token, :end, :eol, :identifier]` |

**Root Cause**: The error is emitted for unexpected `end`, but the actual `:end` token still flows through to the output. Recovery doesn't consume or suppress it.

### Category D: Synthesis Issues (P1)
**Count**: 2 failures
**Pattern**: Wrong token type or missing synthesis

| Test # | Line | Input | Expected Token | Actual Token | Issue |
|--------|------|-------|----------------|--------------|-------|
| 16 | 988 | `":\"foo"` | `:atom_safe_end` | `:atom_unsafe_end` | Wrong end token type |
| 9 | 1254 | `"{ [ ) }"` | `:\"(\"` in output | Missing | No synthetic `(` for unexpected `)` |

**Root Causes**:
- **Wrong token**: `synthesize_end_for_kind` at line 1028-1029 uses `:atom_unsafe_end` but test expects `:atom_safe_end`. May be test bug or logic issue.
- **Missing synthesis**: The `)` is unexpected but synthesis logic doesn't trigger, or the synthetic `(` is consumed by subsequent error recovery.

### Category E: Token Ordering Issues (P2)
**Count**: 2 failures
**Pattern**: Tokens appear in wrong order after errors

| Test # | Line | Input | Expected Order | Actual Order |
|--------|------|-------|----------------|--------------|
| 2 | 269 | `"([) + x"` | `+` in valid tokens | Valid tokens don't match pattern |
| 22 | 606 | `"Foo(1 + 2)"` | `[:alias, :"(", :error_token, :int, :dual_op, :int, :")"]` | `[:alias, :error_token, :dual_op, :int, :error_token, :"(", :")", :error_token, :")"]` |

**Root Cause**: Complex error cascades scramble emission order. Multiple synthesis events and error recoveries interleave incorrectly.

### Category F: Extra Closer Tokens (P2)
**Count**: 2 failures
**Pattern**: Unexpected tokens or wrong token types

| Test # | Line | Input | Issue |
|--------|------|-------|-------|
| 19 | 1267 | `"%{ foo..."` | Test expects `:%` token but tokenizer emits `:%{}` |
| 11 | 1230 | (cont'd) | Last valid token is `)` instead of `baz` |

**Root Cause**: Map tokenization emits composite `:%{}` token instead of bare `:%`. Test may be wrong, or tokenizer should emit separately.

### Category G: Missing Tokens Before Error (P0)
**Count**: 2 failures
**Pattern**: Context-specific recovery doesn't emit tokens that should precede error

| Test # | Line | Input | Expected | Actual |
|--------|------|-------|----------|--------|
| 23 | 473 | `"foo:bar + baz"` | `[:identifier, :error_token, :identifier, :dual_op, :identifier]` | `[:error_token, :dual_op, :identifier]` |
| 21 | 1330 | `String.duplicate(<<0>>, 10) <> "ok"` | `ok` identifier in output | Empty valid tokens |

**Root Causes**:
- **Test #23**: Keyword spacing error should emit `foo` identifier before error at `:`. Currently `adjust_recovery` line 1109-1113 only consumes `:` but doesn't emit `foo`.
- **Test #21**: Multiple nulls consume everything including `ok`. Same as greedy scan issue.

---

## Root Cause Analysis

### RC1: Greedy Scan Consuming Valid Tokens
**Location**: `lib/toxic/driver.ex:1265-1299` (`scan_to_sync` and `do_scan_to_sync`)

**Problem**: When `error_max_skip` is exceeded (line 1269-1272), the fallback calls:
```elixir
defp do_scan_to_sync(rest, state, scanned) when scanned >= state.error_max_skip do
  # Fallback: consume a single codepoint
  consume_one(rest, state)
end
```

But `consume_one` returns `{new_rest, line, col}` where `new_rest` is the ENTIRE remaining input after consuming one character. This doesn't limit the error span—it just advances position by one and leaves all remaining input available, which then gets scanned again or consumed by the next error detection loop.

**Fix**: Change fallback to return position advanced by one grapheme cluster AND truncate the consumed portion from the error span calculation. The error meta should end at the single consumed character, not scan beyond.

### RC2: Single Error for Consecutive Invalid Characters
**Location**: `lib/toxic/driver.ex:1048-1054`

**Problem**: After emitting error and advancing, the "always make progress" check forces minimal consumption:
```elixir
{new_rest, new_line, new_column} =
  if new_line == state.line and new_column == state.column do
    consume_one(rest, state)  # Forces advance
  else
    {new_rest, new_line, new_column}
  end
```

Then `next(new_rest, new_state)` is called, but the next character (another `\0`) is now at the front of `new_rest`. However, the scan has already advanced past it if the error consumed multiple characters. The second `\0` should trigger a NEW error, but it's skipped.

**Fix**: After emitting error, call `next(new_rest, new_state)` to immediately re-tokenize. The minimal progress check should only apply to the error span calculation, not to preventing re-detection of subsequent errors.

### RC3: Unexpected Closers Producing Multiple Errors
**Location**: `lib/toxic/driver.ex:1076-1084`

**Problem**: For unexpected closers, the code synthesizes an opener (line 1070) AND emits the actual closer token (lines 1080-1084):
```elixir
post_actual_closer =
  case actual_closer_from_reason(error) do
    nil -> []
    closer_atom -> [{closer_atom, meta(new_line, new_column, new_line, new_column, nil)}]
  end
```

This emitted closer then flows into normal tokenization, which sees it as ANOTHER unexpected closer and emits a second error.

**Fix**: Remove `post_actual_closer` logic entirely. When synthesis is enabled, the synthetic opener is emitted and the actual closer is consumed as part of the error span. When synthesis is disabled, the actual closer should remain in the input to be processed normally (not emitted as part of error recovery).

### RC4: Reserved `end` Token Still Emitted After Error
**Location**: `lib/toxic/tokenizer.ex` or terminator handling (need to investigate)

**Problem**: Error is emitted for unexpected `end`, but the `:end` token is still emitted afterwards. The error recovery doesn't consume or suppress it.

**Fix**: After emitting error for unexpected `end`, either:
1. Consume the `end` keyword from input (3 characters) so it's not re-tokenized, OR
2. Set a flag in recovery state to suppress the next `:end` emission

Prefer option 1: consume `end` from input during recovery.

### RC5: EOL Emission After Errors
**Location**: `lib/toxic/driver.ex:1086-1091`

**Problem**: When error spans a newline (e.g., VC conflict marker on line 1 errors, newline at end of line 1 is consumed, but deferral still contains `:eol`), the deferred `:eol` is emitted before the error:
```elixir
new_output =
  state.output ++
    Enum.reverse(state.deferrals) ++  # <-- :eol from VC line emitted here
    pre_inserted ++ pre_synth ++ [error_token] ++ post_inserted ++ post_synth ++ post_actual_closer
```

But if the error consumed the newline, the `:eol` is stale.

**Fix**: When error consumes a newline (detected by `new_line > state.line`), clear `state.deferrals` before emitting error.

### RC6: Missing Pre-Error Token Emission
**Location**: `lib/toxic/driver.ex:1107-1174` (`adjust_recovery`)

**Problem**: Context-specific recovery for keyword spacing at line 1109-1113:
```elixir
:keyword_missing_space_after_colon ->
  case rest do
    [?: | _] -> {tl(rest), state.line, state.column + 1, [], state.scope}
    _ -> {def_rest, def_line, def_col, [], state.scope}
  end
```

This consumes `:` but doesn't emit the `foo` identifier that should come before the error. The tokenizer detected `foo:bar` as an error, but recovery should parse `foo` as a valid identifier, emit it, THEN emit error at `:`, THEN continue with `bar`.

**Fix**: Expand keyword case to:
1. Parse prefix before `:` as identifier (extract from `rest` up to `:`)
2. Emit identifier as pre-error token
3. Consume `:`
4. Continue with remainder

This requires backtracking in input or storing parsed identifier from the original error context.

---

## Proposed Fix Plan (Prioritized)

### P0: Critical Fixes (Must Fix First)

#### P0.1: Fix Greedy Scan Consuming Valid Tokens
**File**: `lib/toxic/driver.ex:1269-1272`
**Change**: Modify fallback to return after consuming one cluster and limit error span
**Implementation**:
```elixir
defp do_scan_to_sync(rest, state, scanned) when scanned >= state.error_max_skip do
  # Fallback: consume ONLY one codepoint for error span
  case :unicode_util.gc(rest) do
    [cluster | new_rest] when is_list(cluster) ->
      {next_line, next_col} = advance_pos_cluster(cluster, state.line, state.column)
      {rest, next_line, next_col}  # Return original rest with advanced position, NOT new_rest
    [codepoint | new_rest] when is_integer(codepoint) ->
      {next_line, next_col} = advance_pos(codepoint, state.line, state.column)
      {rest, next_line, next_col}
    [] ->
      {[], state.line, state.column}
  end
end
```
**Impact**: Fixes 5+ continuation failures (Tests #1, #5, #11-15, #21)

#### P0.2: Emit Multiple Errors for Consecutive Invalid Chars
**File**: `lib/toxic/driver.ex:1048-1054`
**Change**: Remove or adjust "always make progress" guard to allow re-detection
**Implementation**: The minimal progress check should only prevent infinite loops on the SAME error, not prevent detecting new errors. After advancing, the next call to `next()` should re-scan from the new position. The issue is that `scan_to_sync` may have skipped over the second invalid char.

Actually, the real issue is in `do_scan_to_sync`: when scanning, if it encounters another invalid char, it keeps scanning instead of stopping. It only stops at sync points (`;`, newline, closer, comma, comment, whitespace).

**Better Fix**: Add invalid-char detection to `do_scan_to_sync` stop conditions. If the current character is another control char or invalid token, STOP scanning and let error recovery handle it as a new error.

**Impact**: Fixes 3 failures (Tests #7, #4, #10)

#### P0.3: Remove Duplicate Closer Emission
**File**: `lib/toxic/driver.ex:1076-1084`
**Change**: Remove `post_actual_closer` logic entirely
**Implementation**:
```elixir
# DELETE lines 1076-1084
# post_actual_closer = ...

# UPDATE line 1091 to remove post_actual_closer
new_output =
  state.output ++
    Enum.reverse(state.deferrals) ++
    pre_inserted ++ pre_synth ++ [error_token] ++ post_inserted ++ post_synth
```

The actual closer should either:
- Be consumed by error recovery (included in error span), OR
- Remain in `new_rest` to be processed by next tokenization call

When synthesis is enabled for unexpected closers, we emit synthetic opener + error. The actual closer in input should then be processed normally (as a valid closer that matches the synthetic opener).

**Impact**: Fixes 4 failures (Tests #6, #8, #15, #20)

#### P0.4: Emit Tokens Before Errors in Context-Specific Cases
**File**: `lib/toxic/driver.ex:1109-1113` (keyword case)
**Change**: Parse and emit identifier before error for keyword spacing
**Implementation**: This is complex because we need to extract the identifier from the original input before the `:`. The error reason should include the parsed identifier in `details`.

**Alternative**: Move keyword spacing detection to emit the identifier BEFORE returning error. This is a tokenizer-level change, not recovery-level.

**Better approach**: In `adjust_recovery`, check if error is `:keyword_missing_space_after_colon` and if `rest` starts with identifier chars before `:`. Parse those chars as identifier, emit as pre-error token.

But we're AFTER the error has been detected. The identifier `foo` has already been scanned as part of `foo:bar`. We need to:
1. Check error details for the full token chars (should be `foo:bar`)
2. Split at `:` to extract `foo` and `bar`
3. Emit `foo` identifier, consume through `:`, leave `bar` in rest

**Impact**: Fixes 1 failure (Test #23)

### P1: Important Correctness Fixes

#### P1.1: Suppress `:end` Token After Unexpected End Error
**File**: `lib/toxic/driver.ex:1158` (adjust_recovery, add case for `:reserved_unexpected_end`)
**Change**: Consume `end` keyword (3 chars) from input
**Implementation**:
```elixir
:reserved_unexpected_end ->
  case rest do
    [?e, ?n, ?d | new_rest] ->
      {new_rest, state.line, state.column + 3, [], state.scope}
    _ ->
      {def_rest, def_line, def_col, [], state.scope}
  end
```
**Impact**: Fixes 1 failure (Test #3)

#### P1.2: Clear EOL Deferral When Error Spans Newline
**File**: `lib/toxic/driver.ex:1086-1091`
**Change**: Clear deferrals if error consumed newline
**Implementation**:
```elixir
# Before building new_output:
deferrals_to_emit =
  if new_line > state.line do
    # Error consumed newline, drop any :eol deferral
    Enum.reject(state.deferrals, fn tok -> elem(tok, 0) == :eol end)
  else
    state.deferrals
  end

new_output =
  state.output ++
    Enum.reverse(deferrals_to_emit) ++
    pre_inserted ++ pre_synth ++ [error_token] ++ post_inserted ++ post_synth
```
**Impact**: Fixes 1 failure (Test #17)

#### P1.3: Fix Atom Safe/Unsafe End Token Mismatch
**File**: `lib/toxic/driver.ex:1028-1029`
**Investigation needed**: Check if `:atom_safe_end` vs `:atom_unsafe_end` distinction is correct. The test input is `":\"foo"` which is an unsafe atom (quoted). Why does test expect `safe_end`?

Review test or synthesis logic.

**Impact**: Fixes 1 failure (Test #16) — may be test bug

#### P1.4: Fix Mismatched Closer Synthesis
**File**: `lib/toxic/driver.ex:1530-1548` (`synthesize_from_reason`)
**Investigation needed**: Why doesn't `{ [ ) }` trigger synthesis of `(` for the unexpected `)`?

Check if `token_display` is set correctly in the error for unexpected `)`.

**Impact**: Fixes 1 failure (Test #9)

### P2: Edge Cases and Complex Scenarios

#### P2.1: Fix String/Interpolation Error Continuation
**Files**: Multiple (string error handling)
**Investigation needed**: Why do string errors with bidi/break chars consume the `+ 1` suffix?

Likely related to P0.1 greedy scan issue.

**Impact**: Fixes 4 failures (Tests #12-15)

#### P2.2: Fix Token Ordering in Complex Error Sequences
**Files**: Multiple
**Investigation needed**: Alias `(` error and mismatched delimiter cascade produce scrambled tokens

**Impact**: Fixes 2 failures (Tests #2, #22)

#### P2.3: Fix Map Token Emission
**Investigation needed**: Is `:%` vs `:%{}` a test bug or tokenizer issue?

**Impact**: Fixes 1 failure (Test #19)

---

## Implementation Order

1. **P0.3** - Remove duplicate closer emission (10 min, high confidence)
2. **P0.1** - Fix greedy scan fallback (15 min, medium confidence)
3. **P0.2** - Multiple consecutive errors (20 min, medium confidence)
4. **P1.1** - Suppress end token (10 min, high confidence)
5. **P1.2** - Clear EOL deferral (15 min, high confidence)
6. **P0.4** - Pre-error token emission (45 min, low confidence - needs design)
7. **P1.3** - Atom token investigation (15 min)
8. **P1.4** - Synthesis investigation (20 min)
9. **P2.1** - String continuation (covered by P0.1?)
10. **P2.2** - Complex ordering (investigation needed)
11. **P2.3** - Map token (investigation needed)

**Estimated Total Time**: 3-4 hours for P0-P1 fixes

---

## Success Criteria

- All 131 tests pass in `test/toxic_tolerant_mode_test.exs`
- No regressions in `test/toxic_erros_test.exs` (strict mode)
- Position accuracy maintained after all recoveries
- Forward progress guaranteed (no infinite loops)

---

## Notes

- P0 fixes should address ~15 failures directly
- P1 fixes should address ~4 more
- P2 requires investigation and may reveal deeper issues
- Some failures may be related (e.g., string continuation may be fixed by greedy scan fix)

**Next Steps**: Implement P0.3 first (safest change), then P0.1, then reassess test results before proceeding.

---

## Addendum: Revisions After Attempted Fixes (post-run review)

This addendum refines the plan based on the current `lib/toxic/driver.ex` behavior and the exact test failures seen in `test/toxic_tolerant_mode_test.exs`.

### A. Don’t add a global “token-start” stop in `scan_to_sync` (revise P0)
- Why: A blanket token-start stop proved too coarse and broke atoms/keywords/maps and identifier sanitization. Tokenization after an error must be context-aware, not character-heuristic driven.
- Action: Keep `scan_to_sync` focused on semicolon/newline/comma/comment/whitespace/closer. For immediate single-char errors like control chars (`:unexpected_token`), handle them in `adjust_recovery/6` by not scanning at all and letting the minimal-progress fallback consume exactly the offending grapheme. This yields separate errors for consecutive invalid chars and preserves the next identifier/number intact without special token-start logic.
- Impact: Fixes continuation for `foo\rbar`, `\0` sequences, and avoids regressions in atoms/keywords/maps.

### B. Keep actual closer emission but balance scope (revise P0.3)
- Why: Removing `post_actual_closer` caused missing actual closers in output. Some tests expect `[:error_token, synthetic_opener, actual_closer, ...]` ordering for unexpected closers.
- Problem today: Appending the closer directly to `output` does not update the terminator stack, leaving the synthetic opener unmatched and triggering an extra EOF error.
- Action: Keep emitting `post_actual_closer`, but also immediately balance the scope by popping the just-pushed opener in state (i.e., mirror `check_terminator`’s effect). This preserves output order and prevents stray EOF “missing closer”. Alternatively (future hardening), special-case the minimal-progress fallback to not consume the closer when a synthetic opener was inserted so the closer is processed via the normal tokenizer path.
- Impact: Preserves expected closer appearance while eliminating duplicate/missing-closer regressions.

### C. Alias followed by `(` ordering (P0.5, refined)
- Problem: For `Foo(1 + 2)`, tests expect `[:alias, :"(", :error_token, ...]`. Current recovery emits the error but does not ensure `"("` appears before the error.
- Action: In `adjust_recovery/6`, add a case for `:alias_unexpected_paren` that inserts `:"("` as a pre-error token with proper 1-char meta at the current position AND consumes that `(` from `rest` (advance by one). This avoids duplication (the inserted token stands in for the actual input paren) and satisfies the expected ordering.
- Impact: Fixes ordering in “unexpected token after alias” tests.

### D. EOL deferral cleanup when newline is in error span (confirm P1.2)
- Problem: When an error consumes a newline (e.g., VC conflict marker line), a deferred `:eol` can be incorrectly emitted before the error.
- Action: If `new_line > state.line`, drop any `:eol` from deferrals before building `new_output`.
- Impact: Stops spurious `:eol` in continuation tests.

### E. Tighten minimal-progress fallback (refine P0.1)
- Problem: Fallback consumption must not swallow the next structural closer; otherwise we are forced to re-emit the closer artificially.
- Action: General rule: consume exactly one grapheme for error span. Special case: if we just synthesized an opener for an unexpected closer, do not consume the next closer via fallback. Either (a) balance scope and still emit `post_actual_closer` as above, or (b) skip fallback consumption in this narrow case so the closer remains in `new_rest` and is processed by normal tokenization. Both options avoid infinite loops because we have pending output to drain before revisiting the same position.

### F. Strings/interpolation character errors (clarify P2.1)
- Problem: After string char errors (bidi/break), continuation (`+ 1`) should still be tokenized.
- Action: With the improved stop-heuristics, rely on `stop_at_closer?/2` (already implemented) to stop at the string/atom/sigil closer. Ensure the fallback does not pre-consume the closer so the next step can close the context and continue.

### G. Updated Implementation Order
1) Adjust `adjust_recovery/6` for `:unexpected_token` to “don’t scan; let fallback consume 1 grapheme” (replaces token-start stop)
2) Keep `post_actual_closer`, but balance scope when emitting it (no unmatched opener at EOF)
3) Clear `:eol` when newline is in error span (P1.2 quick win)
4) Alias `(` pre-insert in `adjust_recovery/6` and consume `(` from `rest`
5) Consume `end` in recovery (P1.1)
6) Keyword spacing pre-error emission (P0.4)
7) Atom end token type audit (P1.3)
8) Mismatched closer synthesis audit (P1.4)
9) String continuation validation (P2.1)
10) Complex ordering + map follow-ups (P2.2/P2.3)

These changes align the plan with `@TOLERANT_MODE_GPT.md` and `@TOLERANT_FINISH_PLAN.md`, while covering uncovered areas surfaced by the current failures.
