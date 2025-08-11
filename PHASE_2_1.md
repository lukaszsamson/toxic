# Phase 2.1 Work Plan: Convert Recursive Tokenizer to Driver Loop

Goal: Refactor the recursive, list-producing tokenizer into a driver-compatible, single-token scanning loop. This enables the Elixir stream to drive the tokenizer, surface live terminators, and stream linearized fragments and interpolation events.

This plan lists all code areas to update with concrete instructions for a coder model.

## A. Introduce scan_token/1 and driver loop entry points

- Add a new internal function:
  - `scan_token(Driver) -> {ok, Token, Driver1} | {eof, Driver1} | {error_token, Meta, Reason, Driver1}`
  - It must not build or return token lists. It returns exactly one token or error per call, updating `Driver1` with the new cursor and scope state.
- Create light wrappers:
  - `next(Driver)` just calls `scan_token/1` and handles strict/tolerant mode decisions for errors.
  - Keep existing list-based `tokenize/4` by repeatedly calling `next/1` until EOF and collecting tokens (compat path).

## B. Replace recursion in tokenize/5 family

All clauses of `tokenize(String, Line, Column, Scope, Tokens)` and helper functions that call it recursively must be reworked to operate on driver state and return a single token.

Key areas to transform:

1) EOF and VC markers
- Clauses around lines ~338–373 handling end-of-input and VC markers. Replace calls like `tokenize(Rest, ...)` with driver state updates and a single token return (or `eof`).

2) Numbers
- Clauses ~376–408 and helpers `tokenize_number/4`. Convert to consume from driver input and emit `{int, ...}` or `{flt, ...}` once, updating `line/column/offset` accordingly.

3) Comments
- Clauses ~393–401 and `tokenize_comment/2`. In streaming mode, either: (a) skip comments or (b) emit comment tokens if configured (optional). Ensure no recursive call; return next token after consuming a comment region.

4) Sigils
- Clauses ~404–411, 2026–2121. Emit `{sigil_start, ...}`, then switch to interpolation streaming mode (see Section D) and subsequently return fragments/events per call.

5) Char literals
- Clauses ~415–467. Consume a single char literal and emit `{char, ...}`; handle newline-escaped case; update position; return.

6) Heredocs
- Clauses ~471–478, handler `handle_heredocs/6` (~1008–1040). Replace `handle_heredocs` list-building logic with driver mode switching:
  - On opening delimiter: emit `{bin_heredoc_start|list_heredoc_start, ...}` and set mode to `{interp, heredoc, Quote, Delim, Indent}`.
  - Subsequent `scan_token/1` calls yield `string_fragment`, `{begin_interpolation,...}`, `{end_interpolation,...}`, and finally `{*_heredoc_end, ...}`.

7) Strings
- Clauses ~481–487, handler `handle_strings/6` (~1060–1142). Similar to heredocs: emit start marker and switch to string interpolation mode; avoid list accumulation.

8) Operator atoms and non-operator atoms
- Clauses ~488–546, 703–775. Continue to emit token(s) as before but avoid tail recursion; return a single token with updated driver state.

9) Three/two/single token operators
- Clauses ~564–700 and helpers `handle_unary_op/8`, `handle_op/8`, `handle_dot/6`, `handle_dot/…`. Convert to single-token emission:
  - Use lookahead from driver input instead of recursive `tokenize` calls to disambiguate.
  - Apply `add_token_with_eol` equivalent in-driver (see Section E) without relying on previously emitted tokens.

10) Containers + punctuation, terminators
- Clauses ~594–621 and `handle_terminator/…` (~1779–1927). Update `scope.terminators` directly in driver state and emit the opener/closer token. Do not call `tokenize/…` recursively.

11) Spaces and EOL
- Clause ~812–815 and `tokenize_eol/4` (~964–968). Implement EOL policy in-driver (see Section E). In streaming embed mode, do not emit `{eol, ...}`; advance line/column and carry EOL counts into the next token’s meta.

12) Dot handling and quoted calls
- Clauses ~974–1323. Convert to single-token emission with quoted identifier start/end markers in linearized mode. Maintain use of `check_call_identifier_multiline`-like logic to choose `paren_identifier/bracket_identifier/identifier`.

13) Identifiers and keywords
- Clauses ~165–204 and ~1636–1679, 1680–1712, 1958–2054. Convert to single-token scanning:
  - `tokenize_identifier/5` should return enough info to produce one token without recursing.
  - Keyword handling (`tokenize_keyword/*`) should emit a single token and update state.

## C. Driver input consumption API

- Introduce helper functions that operate on the driver input without recursion:
  - `driver_peek(Driver, N) -> {ListOfCPs, Driver}` (non-consuming peek of N codepoints)
  - `driver_take(Driver, N) -> {TakenCPs, Driver1}` (consume N codepoints)
  - `driver_take_while(Driver, Pred) -> {TakenCPs, Driver1}`
  - These helpers update `offset/line/column` and maintain a small lookahead cache.

## D. Interpolation streaming integration

- Replace `toxic_interpolation:extract` calls with a streaming variant:
  - Maintain a mode stack in the driver: `mode=[normal | {interp, Kind, Quote, Delim, Indent}]`
  - In `{interp, ...}` mode, `scan_token/1` should:
    - Emit `{string_fragment, FragMeta, Bin}` chunks up to `#{` or closing delimiter
    - On `#{`, emit `{begin_interpolation, Meta, Kind}` and push `normal` mode; track a matching `}` on the terminator stack
    - On `}`, emit `{end_interpolation, Meta, Kind}` and pop interpolation mode
    - On close delimiter, emit `*_end` and pop mode
  - Unescape per fragment; on unescape error, return `{error_token, Meta, Reason, Driver1}` and perform sync skipping as configured

## E. EOL embed policy and rewrites (pre-emit)

- Embed EOL counts into token metas:
  - Maintain an `eol_count` in driver state after consuming line breaks
  - When emitting the next non-EOL token, set its meta extra to include the `eol_count`, then reset the counter
- Implement in-driver versions of:
  - `previous_was_eol/1` → read `eol_count`
  - `add_token_with_eol/2` → no-op in embed mode; in emit mode, emit `{eol, Meta}` tokens when needed (optional)
- Apply space-sensitive rewrites before emission using driver lookahead:
  - `identifier` → `op_identifier`
  - `not` + `in` → single `in_op` with composed meta
  - `do_identifier` rebinding for `do`

## F. Error-tolerant mode in driver

- On lexical error:
  - Return `{error_token, Meta, Reason, Driver1}`
  - If `error_mode=tolerant`, implement sync skipping:
    - `;` → consume to next semicolon
    - newline → consume to line end
    - closer → consume to matching closer (consult terminator stack)
  - If `strict`, stop after first error (driver returns `{eof, Driver1}` and records sticky error)

## G. Keep batch API for compatibility

- Re-implement `tokenize_with_ranges/4` by iterating `next/1` and collecting tokens until EOF (or error in strict mode), then return `{ok, NewLine, NewColumn, Warnings, Tokens, Remaining}` with correct tail string computed from driver.

## H. Checklist of modules/functions to touch

- `src/toxic_tokenizer.erl`
  - `tokenize/5` — all clauses; replace recursion with driver state transitions
  - `handle_strings/6`, `handle_heredocs/6`, `tokenize_sigil_contents/…` — convert to mode switching and event emission
  - `handle_unary_op/8`, `handle_op/8`, `handle_dot/6` — single-token emission with rewrites and dot-specific logic
  - `tokenize_identifier/5`, `tokenize_keyword/*` — return single token with updated state
  - EOL helpers: consolidate into driver state (remove `reset_eol/1`, `add_token_with_eol/2` dependencies where possible)
  - Terminator helpers: keep `check_terminator/*` logic but make them update `Driver#scope.terminators` directly and return the opener/closer token
  - New driver helpers: `driver_peek/2`, `driver_take/2`, `driver_take_while/2`
  - New entry points: `init_driver/4`, `next/1`, `current_terminators/1`, `peek_missing_terminator/1`, `scan/5` (if not already added in Phase 1)
- `src/toxic_interpolation.erl`
  - Add `extract_stream/…` API emitting events (fragment/begin/end/done/error)
  - Refactor unescape to work incrementally over fragments
- `lib/toxic/token_stream.ex`
  - Ensure it delegates to driver-based `:toxic_tokenizer.next/1` only; remove old `fetch_tokens/…`
  - Implement synthetic closer insertion by requesting a token from driver when needed (Phase 5.2)

## I. Acceptance

- The driver can lex the entire input token-by-token without building a list, producing identical output (modulo EOL embed policy) to the current implementation when collapsed.
- Elixir `TokenStream` sees live terminator stack and stable tokens via `next/peek/pushback`.
- String/sigil/heredoc/interpolation constructs are emitted incrementally using linearization markers and fragments.
- Tolerant mode surfaces `{error_token, …}` and resumes after sync points.
