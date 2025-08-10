### Toxic Streaming Tokenizer API (for Pratt parser)

This document proposes a streaming lexer interface built on top of the existing tokenizer, optimized for a Pratt-style parser with lookahead and pushback, and ready for incremental re-lexing. It aims to keep existing token shapes and range metadata while providing stable streaming semantics.

### Goals
- Consistent streaming of tokens with explicit span metadata and optional linearization markers.
- O(1) lookahead (peek) and pushback for Pratt parsing decisions.
- Incremental lexing by ranges (re-lex edited slices only), preserving absolute positions.
- Terminator stack introspection for parser error recovery and editor features.
- Clear stability rules around tokens that can be retroactively altered in legacy mode (EOL handling, etc.).

### Token shapes
- Default output uses `tokenize_with_ranges/4` shapes with exclusive end positions:
  - `{Type, {{StartLine, StartColumn}, {EndLine, EndColumn}, Extra}}`
- Linearization: emits flat markers for string-like constructs:
  - `*_start`/`*_end`, `begin_interpolation`/`end_interpolation`, `string_fragment`, `quoted_identifier_start/end`, `atom_*_start/end`, `kw_identifier_unsafe_start/end`.

### Module and types
- Module: `toxic_stream`

```erlang
%% Opaque streaming handle
-type stream() :: #{
  source := binary() | iolist() | fun((non_neg_integer(), non_neg_integer()) -> {more, binary()} | eof),
  opts := #toxic_tokenizer{},
  buffer := queue(),          %% lookahead buffer of tokens
  pushed := [token()],        %% LIFO pushback stack
  state := internal_state()   %% private lexer driver state (position, terminators, etc.)
}.

-type token() :: term(). %% Same as returned by toxic_tokenizer (ranges)
```

### Construction
- Create from whole input (lazily lexed):

```erlang
toxic_stream:new(String :: iodata(), Line :: pos_integer(), Column :: pos_integer(), Opts :: list()) -> stream().
```

- Create from a producer (chunked input):

```erlang
toxic_stream:new(Producer :: fun((Offset, MaxBytes) -> {more, binary()} | eof),
                 Line, Column, Opts) -> stream().
```

- Options reuse existing tokenizer opts and add stream-specific ones:
  - `{unescape, boolean()}` as today.
  - `{max_batch, non_neg_integer()}` number of tokens to pull per refill.

### Core API (Pratt-friendly)
```erlang
%% Pull next token; returns eof at end
-spec next(stream()) -> {Token :: token(), stream()} | {eof, stream()} | {error, Reason, stream()}.

%% Peek k tokens ahead without consuming (k >= 1; k=1 most common)
-spec peek(stream()) -> {Token :: token(), stream()} | {eof, stream()} | {error, Reason, stream()}.
-spec peek_n(stream(), K :: pos_integer()) -> {Tokens :: [token()], stream()} | {eof, stream()} | {error, Reason, stream()}.

%% Push one token back onto the stream (LIFO). Useful for backtracking.
-spec pushback(stream(), token()) -> stream().

%% Save and rewind (cheap backtracking checkpoints)
-spec checkpoint(stream()) -> {Id :: reference(), stream()}.
-spec rewind_to(stream(), Id :: reference()) -> stream().

%% Current absolute position in terms of ranges (line/column)
-spec position(stream()) -> {{Line, Column}, stream()}.
```

### Incremental lexing
Two entry points are provided:

```erlang
%% Lex only a slice of the source by byte offset and return a stream for it.
-spec slice(stream() | iodata(), OffsetStart :: non_neg_integer(), OffsetEnd :: non_neg_integer(),
           LineBase :: pos_integer(), ColumnBase :: pos_integer(), Opts :: list()) -> stream().

%% Re-lex a changed slice and splice tokens back into an existing stream buffer.
-spec relex_range(stream(), OffsetStart :: non_neg_integer(), OffsetEnd :: non_neg_integer(),
                 NewText :: iodata()) -> stream().
```

Notes:
- The `slice/6` variant is intended for building per-region streams for incremental parsing. It adjusts each token’s ranges by `(LineBase, ColumnBase)` or, if offsets are used, by leveraging a text model (e.g., rope) to map offsets → (line, column).
- `relex_range/4` invalidates buffered tokens overlapping the range and re-fills from a temporary sub-stream. Callers maintain a higher-level token cache keyed by source identity + offset span.

### Terminator stack introspection
Expose the lexer’s bracket/`do`/`fn` stack to aid error recovery and editor UX.

```erlang
-spec current_terminators(stream()) -> {Terminators :: [{Start :: atom(), Meta :: term(), Indentation :: non_neg_integer()}], stream()}.

%% Return the minimal list of missing closers implied by the current stack (top-first)
-spec peek_missing_terminators(stream()) -> {Closers :: [atom()], stream()}.
```

Semantics:
- `current_terminators/1` gives the live stack (see `Scope#toxic_tokenizer.terminators`).
- `peek_missing_terminators/1` maps each opener to its `terminator/1` and returns the list of expected closing tokens without mutating state.

### Stability semantics (streaming rules)
To avoid retroactive mutation of already emitted tokens in streaming mode:
- The stream normalizes EOL behavior:
  - It embeds the EOL count into the token being emitted and does not emit standalone `eol` tokens (unless explicitly requested via `{emit_eol, true}` option).
  - It never needs to later rewrite a preceding `eol` (no `add_token_with_eol/2` surprises to upstream consumers).
- Space-sensitive rewrite (`identifier` → `op_identifier`) is applied before exposing the affected token from the buffer. Hence, once a token is yielded by `next/1`, its tag is stable.
- The `not in` merge is performed as a lookahead rewrite inside the buffer (it peeks the `in` token, merges meta, and updates the buffer head).
- The `do` rebind (`identifier` → `do_identifier`) likewise occurs in-buffer prior to exposure.

These rules allow a Pratt parser to treat tokens yielded by `next/1` as stable without having to “recall” previously seen tokens.

Advanced: If consumers want exact legacy emission (including raw `eol` tokens), pass `{compat_eol, true}`. In that mode, callers must accept that a trailing `eol` can be consumed by a following token; the stream will then surface that consumption as it happens by suppressing the already-buffered `eol` before exposure.

### Linearization in streaming
- Ensures string-like constructs are surfaced as a flat sequence with explicit `{*_start, ...}`, `{string_fragment, ...}`, `{begin_interpolation, ...}`, etc., so the Pratt parser can stream through string parts.

### Error handling
- All APIs return `{error, Reason, Stream1}` without raising, allowing the parser to decide how to proceed.
- Interpolation errors in quoted identifiers and calls are preserved with full meta via existing `interpolation_error/…` formatting.
- Unescape errors propagate from `unescape_tokens/4` and stop further linearization of the current construct.

### Example (Pratt loop sketch)
```erlang
parse_expr(Stream0, MinBp) ->
  {Tok, S1} = ensure(next(Stream0)),
  {Left, S2} = nud(Tok, S1),
  loop_infix(Left, S2, MinBp).

loop_infix(Left, S, MinBp) ->
  case peek(S) of
    {eof, S1} -> {Left, S1};
    {Tok, S1} ->
      case lbp(Tok) >= MinBp of
        true ->
          {_Op, S2} = ensure(next(S1)),
          {Right, S3} = led(Tok, Left, S2),
          loop_infix(Right, S3, MinBp);
        false -> {Left, S1}
      end
  end.

ensure({X, S}) -> {X, S};
ensure({error, R, S}) -> exit({lexer_error, R, S}).
```

### Implementation notes
- Internals: The stream maintains a small token buffer (queue). Refill pulls from the underlying driver using `tokenize/…` in bounded substrings or via a thin driver that exposes the current `Scope` state across calls.
- Range adjustment: For `slice/6` and `relex_range/4`, compose ranges by re-basing metas (start/end inclusive/exclusive maintained) using existing `make_meta/…` helpers.
- Memory: The stream drops older (already yielded) tokens and keeps only a small lookahead window (configurable).

### Open questions (for follow-up PRs)
- Expose a stable, public `#toxic_tokenizer{}` type and constructor for options to avoid leaking record details.
- Decide if the streaming driver should live in `toxic_tokenizer` or as `toxic_stream` for separation of concerns.
- Add a `{emit_eol, boolean()}` compat mode as described under stability semantics.
- Provide `peek_terminator_meta/1` to fetch the full meta of the next expected closer, for richer diagnostics.
