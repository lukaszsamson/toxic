# Toxic Tokenizer – Agent Guide

This guide keeps contributors and agents aligned on how to work in this repo. It summarizes the current architecture and codifies priorities and conventions so changes stay focused and correct.

## Project Snapshot
- Production-ready streaming tokenizer for Elixir with single-token driver and deferrals.
- Linearized output including interpolation begin/end markers; precise ranged metas `{{sl, sc}, {el, ec}, extra}`.
- TokenStream provides buffering, lookahead (`peek/1`, `peek_n/2`), pushback, checkpoints, and position API.
- **Error handling FULLY IMPLEMENTED:** Both strict (halt on error) and tolerant (error recovery) modes working.
- **Test Coverage:** 821 tests, 0 failures, 94.71% overall coverage.
- **Status:** Production-ready for IDE integration and Pratt parser use.

## Key Files
- `lib/toxic/driver.ex` – Low-level single-token driver, contexts, deferrals, terminators.
- `lib/toxic/token_stream.ex` – High-level Elixir API: buffering, lookahead, pushback, checkpoints.
- `lib/toxic/tokenizer.ex` – Main lexical analysis (single-token entry used by Driver).
- `lib/toxic/interpolation.ex` – Interpolation/string/sigil streaming.
- Useful refs: `lib/toxic/terminator.ex`, `lib/toxic/token.ex`, `lib/toxic/scope.ex`.

## Alignment With PLAN.md and PROJECT_STATE.md
- PLAN.md and PROJECT_STATE.md have been updated (2025-10-30) to reflect current status:
  - End-position spans on tokens – ✅ Complete
  - Flat, linear stream – ✅ Complete
  - Lookahead/pushback – ✅ Complete
  - **Error-token emission and sync-point recovery** – ✅ **COMPLETE** (was TODO, now fully implemented)
  - Structural token synthesis – ✅ Complete
  - Tolerant mode with 5+ sync points – ✅ Complete
  - Incremental lexing hooks – ⚠️ Partial: `slice/6` basic, `relex_range/4` stubbed (low priority)
  - Operator precedence metadata – handled in tokenizer/operator modules

## Development Priorities

### ✅ COMPLETED (Production-Ready)
1) **Error Handling** - COMPLETE
   - ✅ Error-token emission: `{:error_token, meta, %Toxic.Error{}}`
   - ✅ Sync-point recovery: semicolon, newline, closer, comma, comment boundaries
   - ✅ Strict vs tolerant modes: both fully working
   - ✅ Position accuracy: maintained during recovery with accurate error spans
   - ✅ Context-specific recovery: 8+ specialized error handlers
   - ✅ Structural synthesis: optional delimiter insertion
   - **Location:** `lib/toxic/driver.ex` lines 1053-1502
   - **Coverage:** 97.72%, 150+ tolerant mode tests

2) **Test Coverage** - EXCELLENT
   - ✅ 821 tests, 0 failures
   - ✅ 94.71% overall coverage
   - ✅ Malformed input and recovery: extensive testing (150+ tests)
   - ✅ Interpolation edge cases: comprehensive coverage
   - ✅ Producer sources: implemented and tested
   - ✅ Checkpoint/rewind: fully tested

### ⚠️ REMAINING (Low Priority)
3) **Incremental Lexing**
   - ⚠️ Enhance `slice/6` for Unicode grapheme support
   - ⚠️ Implement `relex_range/4` for splice/reuse flows
   - ❌ Add offset↔position mapping (not needed currently)
   - ❌ Token splicing rules (future enhancement)

## Testing
- Run all: `mix test`
- With coverage: `mix test --cover`
- Key suites: `test/toxic_test.exs`, `test/toxic/token_stream_test.exs`, and strict error cases in `test/toxic_erros_test.exs`.
- Add new error recovery tests under `test/` (prefer `toxic_error_test.exs` naming).

## Implementation Patterns
- State updates in driver
  - `%{state | line: l, column: c, scope: scope, deferrals: deferrals}`
- Emitting vs deferring
  - Emit: `return_token(token, rest, updated_state)` (updates `recent_token`).
  - Defer: `%{state | deferrals: [token | deferrals]}` with coalescing where needed (EOL).
- Contexts
  - Push on interpolation: `{:interp, kind, allowed?, delim, parent_terms, start_info}`.
  - Pop back to normal and restore parent terminators.
- Terminators
  - Read with `Toxic.Driver.current_terminators/1`.
  - Suggest closer via `Toxic.Driver.peek_missing_terminator/1`.

## Error Handling Conventions
- Prefer returning error tuples over raising: `{:error, reason, rest, state}`.
- **Strict mode:** (fully implemented)
  - TokenStream stores error and returns it on subsequent `next/peek/peek_n` without mutating state.
  - Driver returns `{:error, reason_tuple, rest, state}` and halts.
- **Tolerant mode:** ✅ **FULLY IMPLEMENTED**
  - Emits `{:error_token, meta, %Toxic.Error{}}` inline in the token stream.
  - Advances to configured sync points: `:semicolon | :newline | :closer | :comma | :comment`.
  - Preserves accurate metas and terminator stack during recovery.
  - Context-specific adjustments via `adjust_recovery/5`:
    - Unexpected `end` keyword (consumes and advances)
    - Alias unexpected paren (emits paren token)
    - VC merge conflict markers (consumes entire marker line)
    - Keyword missing space (sanitizes identifier)
    - Map invalid delimiter (emits % token)
    - Heredoc invalid header (synthesizes end token)
    - Identifier sanitization (with confusable normalization)
    - Consecutive semicolons (consumes second)
  - Structural synthesis via `synthesize_from_reason/2`:
    - Creates matching openers for unexpected closers
    - Creates expected closers for mismatched/missing closers
    - Uses zero-length metadata to avoid position drift
    - Controlled by `insert_structural_closers` flag
  - **Configuration:**
    ```elixir
    %Toxic.Driver{
      error_mode: :tolerant,  # or :strict
      error_sync: [:semicolon, :newline, :closer, :comma],
      error_max_skip: 4096,
      insert_structural_closers: true,
      insert_identifier_sanitization: true
    }
    ```

## Common Pitfalls
- Infinite loops: always consume input or deferrals when progressing.
- Position drift: ensure all emissions update end positions correctly; EOL coalescing must rewrite metas consistently.
- Missing tokens: confirm `handle_tokenize_result/2` cases don’t drop emissions during deferral rewrites.
- Interpolation: respect delimiter-specific newline handling for heredocs and sigils.

## Contributor Style
- Prefer specific pattern matching over generic guards in driver/tokenizer clauses.
- Keep changes minimal and localized; avoid broad refactors.
- Maintain linearized token stream invariants (no nested lists).
- Do not raise except for invariants/bugs (e.g., invalid context stack).

## Next Steps Checklist

### ✅ Completed (2025-10-30)
- ✅ Tolerant error path end-to-end (driver + TokenStream integration) - COMPLETE
- ✅ Recovery tests verifying metas, sync behavior, and continued progress - COMPLETE (150+ tests)
- ✅ Update PLAN.md/PROJECT_STATE.md to reflect tolerant mode completion - COMPLETE
- ✅ Update CLAUDE.md with current status - COMPLETE

### ⚠️ Remaining (Low Priority)
- ⚠️ Enhance `slice/6` for Unicode grapheme support
- ⚠️ Implement `relex_range/4` with tests
- Optional: Performance benchmarks and optimization
- Optional: More examples in documentation

## Quick Reference: Error Recovery Implementation

### Key Functions (lib/toxic/driver.ex)
- **`emit_error_and_advance/2`** (lines 1196-1362) - Main recovery orchestrator
- **`adjust_recovery/5`** (lines 1366-1501) - Context-specific adjustments
- **`scan_to_sync/2`** (lines 1584-1677) - Advance to sync point
- **`synthesize_from_reason/2`** (lines 1872-1904) - Structural token synthesis
- **`pending_error/1`** (lines 815-847) - Error prioritization

### Test Files
- `test/toxic_tolerant_mode_test.exs` - 150+ tolerant mode tests
- `test/toxic_errors_test.exs` - 100+ strict mode tests
- `test/toxic_warnings_test.exs` - 200+ warning tests

### API Examples
```elixir
# Tolerant mode (default)
stream = Toxic.new(code, opts: [error_mode: :tolerant])
{:ok, {:error_token, meta, %Toxic.Error{}}, stream} = TokenStream.next(stream)

# Strict mode
stream = Toxic.new(code, opts: [error_mode: :strict])
{:error, reason, stream} = TokenStream.next(stream)

# Check terminators
{terminators, stream} = Toxic.current_terminators(stream)
# terminators = [{opening_token, meta, indent}, ...]
```

## References
- Elixir tokenizer reference: `elixir/lib/elixir/src/elixir_tokenizer.erl` (compare recovery behavior).
- Related designs: Erlang scanner, Roslyn, Tree-sitter; LSP editor requirements.
