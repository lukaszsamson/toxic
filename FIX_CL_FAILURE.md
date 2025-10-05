Remaining Issues Analysis

  Priority Order Recommendation:

  🔴 TACKLE FIRST: Add token-start/invalid-char stop in do_scan_to_sync

  Why this is the highest priority:
  - Fixes ~12 failures (most continuation issues)
  - Root cause for tests #5, #7, #9, #10, #11, #12, #15, #18, #6, #16, #8, #19
  - All "continuation after error" failures stem from greedy scanning
  - Simple, localized change with broad impact

  What it fixes:
  - foo\0bar will stop at b (identifier start) instead of consuming bar
  - x\ry will stop at y instead of consuming it
  - String errors with + 1 will stop at + instead of consuming continuation
  - Multiple nulls will stop at each null (enables multiple errors)

  Implementation: Add stop conditions in do_scan_to_sync at line 1276:
  defp do_scan_to_sync(list = [h | _t], state, scanned) do
    stop? =
      stop_at_semicolon?(h, state) or
      stop_at_newline?(list) or
      stop_at_comma?(h, state) or
      stop_at_comment?(h) or
      stop_at_whitespace?(h) or
      stop_at_closer?(list, state) or
      stop_at_token_start?(h) or          # NEW
      stop_at_invalid_char?(h)             # NEW
    # ...
  end

  defp stop_at_token_start?(h) do
    (h in ?A..?Z) or (h in ?a..?z) or (h == ?_) or  # identifier
    (h in ?0..?9) or                                # number
    (h in [?(, ?[, ?{, ?:])                         # openers, atom
  end

  defp stop_at_invalid_char?(h) do
    h == 0 or (h in 0x00..0x1F and h not in [?\t, ?\n, ?\r])
  end

  ---
  🟡 TACKLE SECOND: Remove post_actual_closer emission

  Why this is second:
  - Currently still present in line 1091 (++ post_actual_closer)
  - The commit added scope balancing but didn't remove the emission
  - Simple deletion, safe change

  What it fixes:
  - Prevents actual closer from triggering second error
  - Clean fix, no side effects

  Implementation: Delete lines 1076-1084 and remove from line 1091

  ---
  🟢 TACKLE THIRD: Clear :eol deferrals when error spans newline

  Why this is third:
  - Fixes test #10 (VC conflict marker extra :eol)
  - Simple, safe change
  - No dependencies on other fixes

  What it fixes:
  - VC conflict marker doesn't emit spurious :eol

  Implementation: Before line 1088, add:
  deferrals_to_emit =
    if new_line > state.line do
      Enum.reject(state.deferrals, fn tok -> elem(tok, 0) == :eol end)
    else
      state.deferrals
    end
  # Then use deferrals_to_emit in new_output instead of state.deferrals

  ---
  🔵 TACKLE FOURTH: Handle alias ( in adjust_recovery

  Why this is fourth:
  - Fixes test #13 (alias error ordering)
  - Requires careful ordering of pre-error tokens
  - More complex than above fixes

  What it fixes:
  - Foo(1 + 2) emits [:alias, :"(", :error_token, ...]

  Implementation: Add case to adjust_recovery:
  {_, :alias_unexpected_paren} ->
    case rest do
      [?( | _] ->
        meta_paren = meta(state.line, state.column, state.line, state.column + 1, nil)
        paren_token = {:\"(\", meta_paren}
        {rest, state.line, state.column, [paren_token], state.scope}
      _ -> {def_rest, def_line, def_col, [], state.scope}
    end

  ---
  📋 Summary Table:

  | Priority | Fix                | Files     | Lines | Est. Time | Tests Fixed | Risk     |
  |----------|--------------------|-----------|-------|-----------|-------------|----------|
  | 🔴 #1    | Token-start stop   | driver.ex | +20   | 15 min    | ~12         | Low      |
  | 🟡 #2    | Remove closer emit | driver.ex | -10   | 5 min     | 0*          | Very Low |
  | 🟢 #3    | Clear :eol         | driver.ex | +5    | 10 min    | 1           | Very Low |
  | 🔵 #4    | Alias ( handling   | driver.ex | +8    | 15 min    | 1           | Low      |

  *Fix #2 prevents regression but doesn't fix new tests directly

  ---
  🎯 Recommended Implementation Order:

  1. Token-start stop (biggest impact, enables multiple error detection)
  2. Remove closer emission (cleanup, prevents future issues)
  3. Clear :eol (quick win)
  4. Alias handling (polish)

  After these 4 fixes, you should be down to ~5 failures (mostly keyword spacing and complex cascade scenarios).


The token-start stop approach is fundamentally flawed because:

  1. Stopping at : breaks atoms, keywords, and maps
  2. Stopping at identifier starts breaks identifier sanitization (we need to consume the bad identifier, not stop at
   it)
  3. The approach is too coarse-grained - we need context-aware stopping, not character-based

  The real issue is that scan_to_sync shouldn't be the place to fix continuation - the problem is elsewhere.


The post_actual_closer was actually needed for
  some cases.
Ah! The actual ) is missing now. The test expects [:error_token, :"(", :")", ...] but we get [:error_token, :"(", 
  ...].

  The issue is that the actual closer IS being consumed by the error recovery and not left in new_rest to be
  processed. The post_actual_closer emission was actually correct for the unexpected closer case.
