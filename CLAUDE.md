# Toxic Tokenizer – Agent Guide

This guide keeps contributors and agents aligned on how to work in this repo. It summarizes the current architecture and codifies priorities and conventions so changes stay focused and correct.

## Project Snapshot
- Streaming tokenizer for Elixir with single-token driver and deferrals.
- Linearized output including interpolation begin/end markers; precise ranged metas `{{sl, sc}, {el, ec}, extra}`.
- TokenStream provides buffering, lookahead (`peek/1`, `peek_n/2`), pushback, checkpoints, and position API.
- Strict error propagation implemented at the stream level; tolerant recovery not implemented yet.

## Key Files
- `lib/toxic/driver.ex` – Low-level single-token driver, contexts, deferrals, terminators.
- `lib/toxic/token_stream.ex` – High-level Elixir API: buffering, lookahead, pushback, checkpoints.
- `lib/toxic/tokenizer.ex` – Main lexical analysis (single-token entry used by Driver).
- `lib/toxic/interpolation.ex` – Interpolation/string/sigil streaming.
- Useful refs: `lib/toxic/terminator.ex`, `lib/toxic/token.ex`, `lib/toxic/scope.ex`.

## Alignment With PLAN.md and PROJECT_STATE.md
- PLAN.md items marked “Done” match code:
  - End-position spans on tokens – present across emissions.
  - Flat, linear stream – interpolation markers emitted, no nested lists.
  - Lookahead/pushback – via TokenStream buffer and push stack.
- Open gaps called out in PROJECT_STATE.md also match code:
  - No error-token emission or sync-point recovery; tolerant mode is a TODO.
  - Incremental lexing hooks are partial: `slice/6` is a basic slice wrapper; `relex_range/4` is stubbed out (commented).
  - Operator precedence metadata is handled in tokenizer/operator modules; Pratt-facing mapping is not a separate table.

## Development Priorities
1) Error Handling (High)
- Add error-token emission in the driver instead of halting on first error.
- Implement sync-point recovery: semicolon, newline, and nearest closer.
- Support strict vs tolerant modes end-to-end (TokenStream opts already allow `:error_mode`).
- Maintain position accuracy during recovery and preserve terminator state.

2) Test Coverage (Medium)
- Add tests for malformed input and recovery behavior (strict vs tolerant).
- Expand interpolation edge cases (e.g., nested, escapes, partial closers).
- Cover function producer sources and checkpoint/rewind behavior.

3) Incremental Lexing (Low)
- Flesh out `slice/6` for Unicode-aware slicing and consistent base positions.
- Implement `relex_range/4` for splice/reuse flows.
- Add offset↔position mapping helpers and token splicing rules.

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
- Strict mode:
  - TokenStream stores error and returns it on subsequent `next/peek/peek_n` without mutating state.
- Tolerant mode (to implement):
  - Emit `{:error_token, meta, reason}` and advance to configured sync points (`:semicolon | :newline | :closer`).
  - Preserve accurate metas and terminator stack during recovery.

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
- Implement tolerant error path end-to-end (driver + TokenStream integration).
- Add recovery tests verifying metas, sync behavior, and continued progress.
- Enhance `slice/6` and scaffold `relex_range/4` with tests.
- Update PLAN.md/TODO.md once tolerant mode lands and incremental hooks start.

## References
- Elixir tokenizer reference: `elixir/lib/elixir/src/elixir_tokenizer.erl` (compare recovery behavior).
- Related designs: Erlang scanner, Roslyn, Tree-sitter; LSP editor requirements.
