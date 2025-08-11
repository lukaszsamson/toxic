### Toxic.TokenStream v2 (Elixir) — Evaluation and Streaming Design

This document evaluates the current Elixir streaming prototype in `lib/toxic/token_stream.ex` and proposes a tokenizer-driven streaming redesign. The goal is to expose a stable, linearized, ranged token stream with lookahead/pushback, error tolerance, incremental re-lexing hooks, and live terminator stack introspection.

---

### Evaluation of current `Toxic.TokenStream`

What works now
- Provides Pratt-friendly surface API: `next/1`, `peek/1`, `peek_n/2`, `pushback/2`, checkpoints, `position/1`, `to_stream/1`.
- Always requests `{produce_ranges, true}` and `{linearize, true}` from the tokenizer.
- Basic EOL policy (`:embed | :emit`) and a tolerant/strict flag skeleton.
- Batching via `max_batch` and internal buffer using `:queue`.

Key gaps and issues
- Pulls full batches via `:toxic_tokenizer.tokenize_with_ranges/4` (list-producing), not a single-token driver:
  - Cannot expose the live terminator stack or other internal state.
  - Cannot switch the scanner into interpolation/string modes and yield fragments incrementally.
  - Error handling is placeholder: on error we synthesize one `{:error_token, ...}` but discard real partial tokens and scope.
- No real source driver: the `(line, column) -> {:more, binary()} | :eof` producer path cannot handle token boundaries or unmatched terminators; it passes the whole returned chunk to list-lexing.
- `current_terminators/1` returns `state[:terminators]`, but `state` never carries tokenizer scope, so this always returns `[]`.
- `peek_missing_terminator/1` is stubbed (incorrect mapping to closers).
- Space-sensitive rewrites (`identifier` -> `op_identifier`), `not in` merge, `do` rebinding are not implemented; dropping standalone `eol` is the only current normalization.
- Incremental `slice/6` and `relex_range/4` are stubs; no offset-to-line/column mapping or token splice logic.
- Conversions `binary -> charlist -> binary` introduce overhead.

Conclusion
- The stream must drive the tokenizer (not the other way around). We need an incremental lexer driver that yields one token at a time with persistent state, so the Elixir stream can:
  - Pull tokens as needed
  - Observe/peek terminators
  - Choose tolerant sync points
  - Surface linearized string/sigil/heredoc parts incrementally

---

### Proposed tokenizer-driven streaming design

High-level idea
- Introduce a streaming driver API in the Erlang tokenizer (non-recursive, no list building). The driver keeps `#toxic_tokenizer{}` and scanning cursors, and produces exactly one token per `next/1` call (or pushes token to a callback).
- The Elixir `Toxic.TokenStream` wraps this driver state and provides Elixir ergonomics.

Driver state (opaque)
- Record (example) maintained internally by the Erlang tokenizer driver:
  - `source`: rope/binary/provider
  - `offset`: byte index into source (or `{line, column}` + line index)
  - `line`, `column`: current absolute position (exclusive end policy preserved)
  - `scope`: `#toxic_tokenizer{produce_ranges=true, linearize=true, ...}` including `terminators`, warnings, flags
  - `mode`: `normal` | `interp(Kind, Quote, Delim, Acc)` for strings/sigils/heredocs/kw_identifyier/atom/identfier. Needs a stack structure for nested interpolations.
  - `error_mode`: `strict | tolerant`
  - `error_sync`: `[semicolon | newline | closer]`; TBD, may use prune mode as guideline
  - small lookahead cache for multi-char ops and space-sensitive rewrites

Driver API (Erlang)
- Initialization
  - `toxic_tokenizer:init_driver(String, Line, Column, Opts) -> {ok, Driver}`
  - Opts force `{produce_ranges,true}` and `{linearize,true}`; `unescape` supported
- Pull one token
  - `toxic_tokenizer:next(Driver) -> {ok, Token, Driver1} | {eof, Driver1} | {error_token, Meta, Reason, Driver1}`
  - Always linearized tokens (markers, fragments, interpolation markers) with ranged metas
- Peek/terminators helpers
  - `toxic_tokenizer:current_terminators(Driver) -> [{Start, Meta, Indent}]`
  - `toxic_tokenizer:peek_missing_terminator(Driver) -> End | nil`
- Optional callback mode
  - `toxic_tokenizer:scan(String, Line, Column, Opts, EmitFun) -> {ok, FinalState}` where `EmitFun(Token, State) -> continue | halt`

Scanner mechanics (core changes)
- Replace recursive token-list accumulation with a tail-recursive loop that:
  1) Scans a single token (or error) from the current cursor and scope
  2) Updates `line/column/offset`, `scope.terminators`, and `mode`
  3) Returns (or emits) the token immediately
- Interpolation/string/heredoc/sigil streaming:
  - On opening delimiter, emit `*_start` and push `mode=interp(...)` onto the stack
  - While in `interp` mode, emit `{string_fragment, FragMeta, Bin}` for raw chunks
  - On `#{`, emit `{begin_interpolation, Meta, Kind}` and push normal mode on to the stack, push opening terminator until `end_interpolation` is reached, then emit `{end_interpolation, ...}` and pop the mode stack resuming `interp`, pop terminator
  - On closer, emit `*_end` (and `sigil_modifiers` if any) and return to `normal`
  - Unescape in streaming chunks; on unescape error in tolerant mode, emit `{error_token, ...}` and sync per policy
- EOL policy:
  - In `embed` mode (recommended for streaming), never emit standalone `eol`; fold the count into the emitted token’s extra (like current operators/keywords). This avoids retroactive mutation of a trailing `eol`.
- Space-sensitive rewrites and merges performed pre-emit:
  - `identifier` -> `op_identifier` rewrite based on immediate lookahead
  - `not` + `in` merged into single `in_op` with composed meta
  - `do` rebinding of preceding identifier into `do_identifier`
- Error-tolerant mode:
  - On lexical error, return `{error_token, Meta, Reason, Driver1}`; `Driver1` represents state after consuming the offending rune(s)
  - Synchronize by scanning forward to the configured sync point(s): semicolon, newline, or the next matching closer by consulting `terminators`

Interpolation module changes
- Provide a streaming variant (or mode flag) in `toxic_interpolation`:
  - `extract_stream(Line, Column, Scope, Interpol, Input, Terminator) -> {event(), NewState}` events:
    - `{:fragment, Meta, Bin}`
    - `{:begin_interpolation, Meta, Kind}`
    - `{:end_interpolation, Meta, Kind}`
    - `{:done, Meta, Terminator}` | `{:error, Meta, Reason}`
  - The tokenizer driver consumes these events and turns them into linearized tokens without buffering whole parts lists.

Minimal insertion helper
- Keep `terminator/1` mapping in tokenizer
- Expose `peek_missing_terminator/1` (top-of-stack), not the whole list
- Elixir stream can request synthetic closer insertion (the driver returns a closer token with `Extra` including `{synthetic, true}`)

---

### Elixir `Toxic.TokenStream` refactor to use the driver

Data structure
- `%Toxic.TokenStream{driver: opaque_driver, buffer: :queue, push: list, opts: options}`

Initialization
- `new/4` calls `:toxic_tokenizer.init_driver/4` and stores the `driver`

Refill
- `refill_buffer/1` calls `:toxic_tokenizer.next/1` up to `max_batch` times:
  - Enqueue `Token` on success
  - If `{error_token, Meta, Reason, Driver1}`, enqueue error token (in tolerant mode), then keep pulling (after driver’s own sync)
  - If `{eof, Driver1}`, set `eof: true`
  - Update internal `driver`

Core ops
- `next/1`, `peek/1`, `peek_n/2`, `pushback/2`, checkpoints/rewind unchanged at API level
- `current_terminators/1` delegates to `:toxic_tokenizer.current_terminators/1` on the driver
- `peek_missing_terminator/1` delegates to driver’s helper

EOL mode and rewrites
- Prefer `:embed` EOL in driver to avoid exposing mutable `eol` tokens. If `:emit` is requested for compatibility, the driver can surface `{eol, Meta}` and the stream will pass them through.

Incremental lexing
- `slice/6` creates a new driver for the slice (rebasing metas to the slice’s absolute `(line_base, column_base)`).
- `relex_range/4` replaces the underlying driver’s input slice and clears buffered tokens overlapping the range; the driver continues from the earliest affected position.

---

### Public signatures summary

Erlang (driver)
- `toxic_tokenizer:init_driver(Input, Line, Column, Opts) -> {ok, Driver}`
- `toxic_tokenizer:next(Driver) -> {ok, Token, Driver1} | {eof, Driver1} | {error_token, Meta, Reason, Driver1}`
- `toxic_tokenizer:current_terminators(Driver) -> [{Start, Meta, Indent}]`
- `toxic_tokenizer:peek_missing_terminator(Driver) -> End | nil`
- `toxic_tokenizer:scan(Input, Line, Column, Opts, EmitFun) -> {ok, FinalState}` (optional callback style)

Elixir
- `Toxic.TokenStream.new/4`
- `Toxic.TokenStream.next/1`, `peek/1`, `peek_n/2`, `pushback/2`
- `Toxic.TokenStream.checkpoint/1`, `rewind_to/2`
- `Toxic.TokenStream.position/1`
- `Toxic.TokenStream.current_terminators/1`, `peek_missing_terminator/1`
- `Toxic.TokenStream.slice/6`, `relex_range/4`

---

### Migration plan
1) Implement tokenizer driver (`init_driver/next/current_terminators/peek_missing_terminator`). Keep existing list-returning APIs for compatibility.
2) Refactor `Toxic.TokenStream` to use the driver; delete batch `fetch_tokens/…` and ad-hoc error token synthesis.
3) Add streaming `toxic_interpolation` entry points and route string/sigil/heredoc through it.
4) Port EOL, space-sensitive rewrites, `not in` merge, and `do` rebinding into the driver pre-emit logic.
5) Validate by enumerating `driver` until EOF and diffing against current `tokenize_with_ranges/…` + `collapse_linear_ranges/1` for a corpus.

---

### Risks / open questions
- Heredoc indentation trimming in fully streaming mode may require buffering at least per-line to compute trimmed fragments correctly.
- Mapping byte offsets to `(line, column)` efficiently suggests a rope or line-index; consider a pluggable source abstraction.
- Error synchronization heuristics may need tuning to balance forward progress vs. excessive skipping.
- Performance: ensure per-token overhead remains low; consider NIFs for heavy unescape if needed.
