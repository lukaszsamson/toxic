## Toxic.Driver state machine – analysis and proposed refactor

### Scope
This document reviews the delayed-emission mechanisms in `lib/toxic/driver.ex` and proposes a unified design to simplify the state machine while preserving behavior.

### Current model (summary)
- State is `{line, column, scope, modes}` where `modes` is a stack (list) with `:normal` at the bottom.
- The driver delegates to `:toxic_tokenizer.tokenize_single/5` and `:toxic_interpolation.extract_stream_event/6`.
- Delayed emission today is encoded by pushing ad-hoc modes onto the `modes` stack:
  - `{:carry_tokens, tokens}`: pass `tokens` into the next tokenizer call (affects folding/previous-token context; also used for EOL folding and `.` lookback).
  - `{:eol_carry, eol_token}`: coalesce consecutive EOLs and delay deciding whether to emit EOL or fold it into the next token class.
  - `{:pending_token, token}`: emit `token` on the next `next/2` call without consuming input.
  - `{:identifier_pending, id_token}`: classify an identifier by peeking next chars (`do`, `(`, `[`, op-identifier) before emitting.
  - `{:await_in_after_eol}`: sentinel so EOL handling can merge `not` + EOL + `in`.
  - `{:call_identifier_pending, token}`: special pending for call identifiers when there is a stored token to emit before the identifier.
  - `{:interp_with_pending, kind, token, delim}`: emit a stored token first, then start interpolation on the next call.
  - `{:sigil_mods_pending, mods_token, len}`: emit sigil modifiers next and consume `len` source characters.
  - Other context modes (not the focus here) include `{:interp, kind, interpolation, delim}` and `{:bol_indent, indent_col}`.

### Observations
- These modes encode two distinct concerns in one stack:
  - **Context**: lexical environment (e.g., interpolation, heredoc, BOL indent).
  - **Deferral**: what to emit or carry across calls (pending emissions, EOL strategies, carries).
- Several modes are variations of the same pattern:
  - "Emit X now, then emit Y next without consuming input": `pending_token`, `call_identifier_pending`, `interp_with_pending`, `sigil_mods_pending`.
  - "Coalesce and decide EOL behavior based on the next token": `eol_carry`, `await_in_after_eol`.
  - "Pass previous tokens to influence next tokenization": `carry_tokens` (includes carrying EOL or `.` or `not`).
  - "Transform a token based on a cheap lookahead": `identifier_pending`.
- EOF handling is duplicated in special-mode clauses to flush pending items.
- The single `modes` stack must interleave context and deferral, which complicates patterns like `:interp` while a `pending_token` is queued.

### Goals for a refactor
- Separate **context** from **deferral**, each with a clear, minimal API.
- Centralize EOF and "emit-before-consume" logic.
- Keep `:normal` and interpolation modes as contexts; move pending/carry/EOL into a common deferral mechanism.
- Reduce the number of `next/2` heads; concentrate the main loop.

### Proposed state shape
Augment `Toxic.Driver` with two orthogonal structures:

- **Context stack** (`contexts`):
  - Values: `:normal`, `{:interp, kind, interpolation, delim}`, `{:bol_indent, indent_col}`, etc.
  - Invariant: bottom is `:normal`.
  - Replaces the context portion of `modes`.

- **Deferral queue/stack** (`deferrals`): uniform representation of delayed actions, processed before calling the tokenizer (pre) and before returning a token (post).
  - Types:
    - `{:pre_carry, [token, ...]}`: pass tokens to the next tokenizer call (unifies `carry_tokens`). Multiple carries append.
    - `{:eol_strategy, %{eol: token, coalesce?: boolean, await_in?: boolean}}`: coalesce EOLs and decide fold/emit on next non-EOL (unifies `eol_carry` and `await_in_after_eol`).
    - `{:emit_next, token, consume: non_neg_integer, after: context_change | nil}`: emit `token` on next `next/2` call; optionally consume `len` chars and apply a context change (unifies `pending_token`, `call_identifier_pending`, `interp_with_pending`, `sigil_mods_pending`).
    - `{:transform_next, token, fun}`: run `fun.(token, peek_input)` to produce the final token (or a new deferral) before emission (unifies `identifier_pending`).

Notes:
- `contexts` remains a stack; `deferrals` is best treated as a small queue where `emit_next` has highest priority, followed by `transform_next`, then `eol_strategy` (when input is empty or a decision is forced). Implementation can use a list with simple pick rules instead of strict FIFO, as long as priority is respected.

### Driver algorithm (single entry `next/2`)
At a high level, each `next/2` iteration would:

1) If there is an `{:emit_next, token, consume: len, after: change}` deferral:
   - Emit `token` immediately.
   - Consume `len` chars from input (if any) and adjust `column`.
   - Apply `after` (e.g., push `{:interp, ...}`) to `contexts`.
   - Return.

2) If there is a `{:transform_next, token, fun}` deferral:
   - Run `fun.(token, peek(input))` (no consumption) to get either a final token or another deferral (e.g., turn into `{:emit_next, ...}`).
   - Replace the deferral accordingly and loop.

3) If there is an `{:eol_strategy, st}` and input starts with EOL:
   - Coalesce EOL (update `st.eol`); loop.
   - If input does not start with EOL:
     - Tokenize next with any `{:pre_carry, ...}` applied.
     - Decide based on the produced token whether to fold EOL (return produced token) or emit EOL first (push `{:emit_next, produced_token}` and return EOL), or carry both into tokenizer (e.g., `not` + EOL + `in`).

4) Otherwise, build carry list from all `{:pre_carry, ...}` deferrals, call `tokenize_single/5`.
   - If result is a non-EOL token:
     - Possibly schedule deferrals depending on special cases:
       - Dot lookback: add `{:pre_carry, [dot]}` and return `dot`.
       - Quoted identifier entering interpolation with a stored begin token: schedule `{:emit_next, begin_token, after: push_interp}` (was `interp_with_pending`).
       - Call identifier with a stored token to emit first: schedule `{:emit_next, identifier}` after emitting stored (was `call_identifier_pending`).
       - Sigil end + modifiers: emit end now, schedule `{:emit_next, mods, consume: len}` (was `sigil_mods_pending`).
       - Identifier: schedule `{:transform_next, id_token, fun}` (was `identifier_pending`).
       - Unary `not` in `:normal`: if `begins_with_in`, add `{:pre_carry, [not]}` and continue; else, arm EOL strategy with `await_in?: true` to suppress EOL before `in`.
     - If `{:bol_indent, indent_col}` present in `contexts`, apply `adjust_bol_operator/3` to the first operator token.
     - Return produced token when appropriate.
   - If result is `{:token, {:eol, _} = eol, ...}`:
     - If current strategy calls for coalescing, set/update `{:eol_strategy, %{eol: eol, coalesce?: true, await_in?: flag}}` and loop.
     - Else, default strategy: coalesce and then decide per next token.
   - If result switches to interpolation: push/pop `contexts` accordingly and possibly schedule `{:emit_next, ...}` as above.

5) EOF:
   - If `{:emit_next, ...}` exists: emit it.
   - Else if `{:transform_next, token, fun}` exists: emit the transformed token immediately.
   - Else if `{:eol_strategy, %{eol: eol}}` exists: emit the (coalesced) `eol`.
   - Else: `{:eof, state}`.

### Mapping: current → proposed
- `{:carry_tokens, ts}` → `{:pre_carry, ts}` (accumulated and cleared after one tokenizer call).
- `{:eol_carry, eol}` + `{:await_in_after_eol}` → single `{:eol_strategy, %{eol, coalesce?: true, await_in?: boolean}}` with decision logic centralized.
- `{:pending_token, tok}` → `{:emit_next, tok, consume: 0, after: nil}`.
- `{:identifier_pending, id}` → `{:transform_next, id, fun}` where `fun` encodes the current `begins_with_do/1`, `(`, `[`, and op-identifier checks.
- `{:call_identifier_pending, tok}` → `{:emit_next, tok, consume: 0, after: nil}` queued after emitting the stored token.
- `{:interp_with_pending, kind, tok, delim}` → `{:emit_next, tok, consume: 0, after: push({:interp, kind, [], delim})}`.
- `{:sigil_mods_pending, tok, len}` → `{:emit_next, tok, consume: len, after: nil}`.
- `{:bol_indent, col}` remains a context (`contexts`), not a deferral.
- `{:interp, ...}` remains a context (`contexts`).

### Benefits
- **Fewer `next/2` heads**: one main clause plus small helpers replaces many ad-hoc mode clauses.
- **Clear separation of concerns**: contexts vs deferrals, reducing accidental interactions and ordering bugs.
- **Unified EOF policy**: one place flushes pending emissions, transforms, and EOL strategies deterministically.
- **Extensibility**: new delayed behaviors modelled as deferrals without inventing new top-level modes.
- **Testability**: deferral resolution is pure and can be unit-tested per type (emit, transform, eol strategy, carry).

### Migration plan (incremental)
1. Introduce `deferrals` (in state) with just `{:emit_next, ...}` and migrate: ✅ DONE
   - `pending_token`, `call_identifier_pending`, `interp_with_pending`, `sigil_mods_pending` → now emitted via `{:emit_next, token, 0 | len, after}`.
   - EOF flushing updated to emit pending `emit_next` before generic EOF.
2. Introduce `{:pre_carry, ...}` and replace `carry_tokens` calls and clauses. ✅ DONE (with compatibility bridge)
   - Implemented `{:pre_carry, [..]}` plus a handler that consumes it before tokenization (including BOL-indent adjustment).
   - Migrated major `carry_tokens` producers to `pre_carry`:
     - Dot lookback, EOL suppression (comment/continuation), `not` + EOL + `in` (single and double carry), comma/semicolon newline folds, assoc `=>` after coalesced EOLs, `await_in_after_eol` handoff.
   - Added a generic compatibility clause to convert a top `{:carry_tokens, carry}` (and `{:carry_tokens, carry}, {:bol_indent, ...}`) into a one-shot `pre_carry` to avoid behavior drift while remaining sites are migrated.
3. Introduce `{:transform_next, ...}` and replace `identifier_pending`. ⏭ NEXT
4. Introduce `{:eol_strategy, ...}` and replace both `eol_carry` and `await_in_after_eol` (move their logic into a single decision function). ⏭ NEXT
5. Split `modes` into `contexts` (stack) and `deferrals` (list). Maintain `ensure_state_valid/1` invariants for `contexts`. ⏭ NEXT
6. Delete now-unused mode clauses and simplify `next/2` to the main algorithm above. ⏭ NEXT

### Current migration status
- Deferrals infrastructure in place with two kinds:
  - `{:emit_next, token, consume_len, after}` for deferred emission and optional context push (interpolation).
  - `{:pre_carry, tokens}` for single-call carry into tokenizer (unifies `carry_tokens`).
- Legacy modes bridged:
  - `{:carry_tokens, ...}` at top of `modes` is auto-converted to `pre_carry` for the next call; `{:carry_tokens, ...}, {:bol_indent, ...}` also converted, preserving BOL-operator adjustment semantics.
  - `pending_token`, `call_identifier_pending`, `interp_with_pending`, `sigil_mods_pending` now mapped to `emit_next` (with consumption for sigil modifiers and context push for interpolation start tokens).

### Notes for upcoming steps
- When introducing `{:transform_next, ...}` for identifiers, port the existing lookahead/classification logic from `{:identifier_pending, ...}` as a pure function.
- When introducing `{:eol_strategy, ...}`, fold coalescing and decision-making (operators, brackets, dot, comments, `not in`) into a single place and remove `eol_carry`/`await_in_after_eol` branches.

### Edge cases covered by the model
- **","/";" newline folding**: remains a fast path; or could be handled by `eol_strategy` if preferred.
- **Dot lookback**: use `{:pre_carry, [dot]}` so tokenizer sees `previous_was_dot`.
- **`not` + EOL + `in`**: `{:eol_strategy, await_in?: true}` suppresses EOL and optionally `{:pre_carry, [not, eol]}` to let tokenizer merge `not in`.
- **Standalone unary at BOL**: `eol_strategy` chooses "emit EOL first, then unary" by scheduling `{:emit_next, unary}` and returning EOL.
- **Assoc `=>` after multiple EOLs**: coalescing stored in `eol_strategy.eol` with `extra` count; when next is `=>`, fold by carrying the coalesced EOL.
- **Quoted identifiers and interpolation**: `{:emit_next, begin_token, after: push_interp}` ensures ordering is preserved.
- **Sigil modifiers**: `{:emit_next, mods, consume: len}` consumes characters and adjusts column without an extra mode.
- **BOL indent fixup**: remains a context that post-processes the first operator token via `adjust_bol_operator/3`.

### Minimal internal APIs
- `push_context/2`, `pop_context/1`.
- `schedule_emit(token, opts)` → adds `{:emit_next, ...}`.
- `schedule_carry(tokens)` → adds/merges `{:pre_carry, ...}`.
- `schedule_eol(eol, opts)` → adds/updates `{:eol_strategy, ...}`.
- `schedule_transform(token, fun)` → adds `{:transform_next, ...}`.
- `peek_input/1` (cheap lookahead helper), `coalesce_eols/1`.

### Risks and mitigations
- Behavior drift in EOL folding: write characterization tests around current `eol_carry` matrix (identifier, unary/not, binary ops, brackets, dot, comments).
- Ordering of deferrals: enforce priority (emit > transform > eol > carry) and document it; property-test against old driver.
- Performance: deferral checks are O(1) small-list operations; avoid repeated allocations by normalizing deferrals after each step.

### Conclusion
A two-structure state—`contexts` (stack) + `deferrals` (small prioritized list)—captures all existing delayed-emission behaviors uniformly. It simplifies `next/2`, centralizes EOF handling, and eliminates ad-hoc pending/carry modes while keeping interpolation and BOL indent as true contexts. This yields a clearer, more maintainable driver with fewer edge-case interactions.