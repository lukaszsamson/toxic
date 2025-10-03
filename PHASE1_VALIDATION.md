# Phase 1 Implementation Validation

## Implementation Review

### ✅ What's Correct

1. **Driver Options** - Correctly added to `Toxic.Driver`:
   - `:error_mode` (default `:tolerant`)
   - `:error_sync` (default `[:semicolon, :newline, :closer, :comma]`)
   - `:error_max_skip` (default `4096`)
   - `:insert_structural_closers` (default `false`)

2. **TokenStream Options** - Properly propagated through TokenStream

3. **Error Branching** - Correct pattern in both places:
   ```elixir
   case state.error_mode do
     :strict -> {:error, reason, string, state}
     :tolerant -> emit_error_and_advance(reason, string, state)
   end
   ```

4. **Deferral Flushing** - Line 897 correctly flushes deferrals BEFORE error token:
   ```elixir
   new_output = state.output ++ Enum.reverse(state.deferrals) ++ [error_token]
   ```

5. **Forward Progress Guarantee** - Lines 886-891 ensure we always consume at least one char

6. **Sync Point Detection** - Lines 923-925 check all sync points correctly

7. **Bounded Scanning** - Line 914 respects `:error_max_skip` limit

### ⚠️ Issues Found

#### Issue 1: `starts_with_list?/2` Unused Variable Warning

**Location**: `driver.ex:1001`

**Problem**:
```elixir
defp starts_with_list?(list, []), do: true  # 'list' unused in guard
```

**Fix**:
```elixir
defp starts_with_list?(_list, []), do: true
```

#### Issue 2: Missing Grapheme Cluster Handling

**Location**: `consume_one/2` and `do_scan_to_sync/4`

**Problem**: Both functions advance by single codepoint, not grapheme cluster.

**Example**:
```elixir
# Input: "foo👨‍👩‍👧‍👦bar"  (family emoji = 7 codepoints, 25 bytes)
# If error at emoji, should skip entire cluster, not partial
```

**Current Code**:
```elixir
defp consume_one([h | t], state) do
  {t, advance_pos(h, state.line, state.column)}  # Only consumes 1 codepoint
end
```

**Fix Needed**:
```elixir
defp consume_one(rest, state) do
  case :unicode_util.gc(rest) do
    [cluster | new_rest] when is_list(cluster) ->
      # Multi-codepoint grapheme cluster
      {new_rest, advance_pos_cluster(cluster, state.line, state.column)}

    [codepoint | new_rest] when is_integer(codepoint) ->
      {new_rest, advance_pos(codepoint, state.line, state.column)}

    [] ->
      {[], state.line, state.column}
  end
end

defp advance_pos_cluster(cluster, line, col) do
  # Clusters count as 1 column regardless of codepoint count
  if Enum.any?(cluster, &(&1 == ?\n)) do
    {line + 1, 1}
  else
    {line, col + 1}
  end
end
```

#### Issue 3: Whitespace Not in Sync List

**Problem**: Design doc says "stop before whitespace" but it's not in default `:error_sync`

**Current**: `[:semicolon, :newline, :closer, :comma]`
**Missing**: Horizontal whitespace (space, tab)

**Why This Matters**:
```elixir
# Input: "foo\0 bar"
# Current: scans past space, stops at 'b'
# Better: stop at space
```

**Fix**: Add whitespace check in `do_scan_to_sync`:
```elixir
defp do_scan_to_sync([h | t] = full, state, scanned) do
  stop? =
    stop_at_semicolon?(h, state) or
    stop_at_newline?(full) or
    stop_at_comma?(h, state) or
    stop_at_comment?(h) or
    stop_at_whitespace?(h) or  # NEW
    stop_at_closer?(full, state)
  # ...
end

defp stop_at_whitespace?(h) when h in [?\s, ?\t], do: true
defp stop_at_whitespace?(_), do: false
```

#### Issue 4: `\r\n` Handling in `advance_pos`

**Problem**: Only handles `\n`, not `\r\n` CRLF sequences

**Current**:
```elixir
defp advance_pos(?\n, line, _col), do: {line + 1, 1}
defp advance_pos(_ch, line, col), do: {line, col + 1}
```

**Issue**: When scanning character-by-character, `\r` is treated as regular char, then `\n` increments line. This is actually OK since `stop_at_newline?` checks the full sequence.

**Verdict**: Not a bug, but could document this behavior.

#### Issue 5: Missing EOF Draining Logic

**Location**: `Driver.next/2` line 62-76

**Problem**: EOF handling doesn't implement tolerant draining

**Current Code**:
```elixir
def next([], %__MODULE__{deferrals: []} = state) do
  case pending_error(state) do
    nil ->
      {:eof, state}

    {:missing_interpolation, interp_context} ->
      {:error, missing_interpolation_reason(interp_context, state), [], state}
    # ... all cases return {:error, ...}
  end
end
```

**Expected (Tolerant Mode)**:
```elixir
def next([], %__MODULE__{deferrals: []} = state) do
  case pending_error(state) do
    nil ->
      {:eof, state}

    error when state.error_mode == :strict ->
      # Existing error returns
      case error do
        {:missing_interpolation, interp_context} ->
          {:error, missing_interpolation_reason(interp_context, state), [], state}
        # ... etc
      end

    error when state.error_mode == :tolerant ->
      # Drain one error, continue
      {error_token, new_state} = emit_pending_error(error, state)
      {:ok, error_token, [], new_state}  # Next call handles remaining errors
  end
end
```

**This is Critical**: Without this, tolerant mode still halts at EOF with pending errors.

#### Issue 6: TokenStream Doesn't Default to `false` for `insert_structural_closers`

**Location**: `token_stream.ex:80`

**Current**: `insert_structural_closers: false` ✅ Correct!

**But GPT doc updated to**: `insert_structural_closers: true` (default)

**Conflict**: Code has `false`, updated spec has `true`

**Recommendation**: Keep `false` for Phase 1 MVP, change to `true` in Phase 2 when synthesis is implemented.

### 📋 Missing Implementations (Expected for Phase 1)

1. ❌ `emit_pending_error/2` - Not implemented
2. ❌ EOF draining loop in `next([], state)`
3. ❌ Grapheme cluster support in scanning
4. ❌ Whitespace sync point

### ✅ What Works

Based on the code, tolerant mode should work for:
- ✅ Lexical errors in normal tokenization (via `tokenize_single`)
- ✅ Interpolation errors (via `tokenize_single` in interp context)
- ✅ Bounded scanning with max skip
- ✅ Sync to semicolon, newline, comma, comment, closer
- ✅ Deferral preservation

**Does NOT work yet**:
- ❌ EOF pending errors (still returns `{:error, ...}`)
- ❌ Grapheme cluster edge cases
- ❌ Whitespace boundaries (minor)

## Test Strategy

The tolerant mode tests should verify:

1. **Forward Progress**: Every error case produces error token and continues
2. **Position Accuracy**: Error token spans are correct
3. **Continuation**: Tokens after error are correct
4. **No Infinite Loops**: Every error advances position
5. **Deferral Preservation**: EOL tokens before errors are not lost

### Test Structure

For each error in `toxic_erros_test.exs`:
1. Add valid tokens after the error
2. Verify error token emitted at correct position
3. Verify continuation tokens are correct
4. Verify no crash/infinite loop

## Recommendations

### Critical (Must Fix Before Testing)
1. ✅ Fix EOF draining logic (add `emit_pending_error/2`)
2. ⚠️ Fix unused variable warning (trivial)

### Important (Should Fix)
3. ⚠️ Add grapheme cluster handling
4. ⚠️ Add whitespace sync point

### Nice to Have
5. ℹ️ Document `\r\n` behavior in `advance_pos`
6. ℹ️ Add debug logging for recovery paths

## Verdict

**Overall Assessment**: Phase 1 is **85% correct**

**Strengths**:
- Core architecture is sound
- Sync point detection is comprehensive
- Deferral handling is correct
- Forward progress guarantee is implemented

**Gaps**:
- Missing EOF draining (critical for completeness)
- Missing grapheme cluster support (important for Unicode correctness)
- Minor: whitespace sync, unused var warning

**Recommendation**:
1. Implement `emit_pending_error/2` and EOF draining
2. Fix unused variable
3. Start testing with current implementation
4. Add grapheme cluster support when failures occur

The implementation is **good enough to start testing** after fixing EOF draining. Grapheme cluster issues will only show up with specific Unicode inputs.
