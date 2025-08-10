### Toxic Streaming Tokenizer API (for Pratt parser)

This document proposes a streaming lexer interface built on top of the existing tokenizer, optimized for a Pratt-style parser with lookahead and pushback, and ready for incremental re-lexing, and error tolerance.

### Goals
- Consistent streaming of tokens with explicit span metadata and optional linearization markers.
- O(1) lookahead (peek) and pushback for Pratt parsing decisions.
- Incremental lexing by ranges (re-lex edited slices only), preserving absolute positions.
- Terminator stack introspection for parser error recovery and editor features.
- Clear stability rules around tokens that can be retroactively altered in legacy mode (EOL handling, etc.).
- Error recovery mode

Key design constraints
- Only range metas are exposed (exclusive end); no legacy metas.
- Only linearized output is exposed; container tokens are always flattened into start/end markers, fragments, and interpolation markers.

Token shapes (always linearized, always ranged)
- Simple: `{Type, {{SL, SC}, {EL, EC}, Extra}}`.
- String-like and quoted constructs are linear:
  - `{bin_string_start|list_string_start, Meta, Delim}` … `{string_fragment, FragMeta, Bin}` … `{bin_string_end|list_string_end, Meta, Delim}`
  - `{bin_heredoc_start|list_heredoc_start, Meta, "\"\"\""|"'''"}` … `{string_fragment, …}` … `{bin_heredoc_end|list_heredoc_end, Meta, Delim, Indent}`
  - `{sigil_start, Meta, SigilAtom, Delim}` … `{string_fragment, …}` … `{sigil_end, Meta, SigilAtom, Delim, Indent}` [+ optional `{sigil_modifiers, Meta, Mods}`]
  - `{begin_interpolation, Meta, Kind}` … inner tokens … `{end_interpolation, Meta, Kind}`
  - `{kw_identifier_unsafe_start, Meta, Quote}` … `{string_fragment, …}`/interpol … `{kw_identifier_unsafe_end, Meta, Quote}` followed by `':'`
  - `{atom_safe_start|atom_unsafe_start, Meta, Quote}` … fragments/interpol … `{atom_safe_end|atom_unsafe_end, Meta, Quote}`
  - `{quoted_identifier_start, Meta, Quote}` … identifier token … `{quoted_identifier_end, Meta, Quote}`
- Error token (tolerant mode): `{error_token, Meta, Reason}` where `Reason` is a human-readable iodata() or structured tuple.
- Synthetic insertions (minimal delimiter insertion): `Extra` may include `{synthetic, true}` and `{synthetic_reason, Why}`.

Module and types
- Module: `toxic_stream`

```erlang
-type token() :: term().

-type stream() :: #{
  source := binary() | iolist() | fun((non_neg_integer(), non_neg_integer()) -> {more, binary()} | eof),
  opts := #toxic_tokenizer{},
  buffer := queue(),          %% lookahead window
  pushed := [token()],        %% LIFO pushback
  state := internal_state()   %% driver state (offsets, ranges, terminators, etc.)
}.
```

Construction
```erlang
toxic_stream:new(String :: iodata(), Line :: pos_integer(), Column :: pos_integer(), Opts :: list()) -> stream().

toxic_stream:new(Producer :: fun((Offset, MaxBytes) -> {more, binary()} | eof),
                 Line, Column, Opts) -> stream().
```

Options (additions to existing tokenizer opts)
- `{produce_ranges, true}` (forced true)
- `{linearize, true}` (forced true)
- `{unescape, boolean()}` (default true)
- `{max_batch, non_neg_integer()}` (tokens per refill, default 256)
- `{eol_mode, embed | emit}`
  - `embed` (default): do not emit standalone `eol`; embed EOL count into token metas as today’s operators/keywords do
  - `emit`: surface `{eol, Meta}` tokens (accept that a trailing `eol` may be suppressed before exposure)
- `{error_mode, tolerant | strict}` (default `tolerant`)
- `{error_sync, [semicolon | newline | closer]}` (default `[semicolon, newline, closer]`)

Core API (Pratt-friendly)
```erlang
-spec next(stream()) -> {token(), stream()} | {eof, stream()}.
-spec peek(stream()) -> {token(), stream()} | {eof, stream()}.
-spec peek_n(stream(), pos_integer()) -> {[token()], stream()} | {eof, stream()}.
-spec pushback(stream(), token()) -> stream().

%% Backtracking checkpoints
-spec checkpoint(stream()) -> {reference(), stream()}.
-spec rewind_to(stream(), reference()) -> stream().

%% Current absolute position (start of next token)
-spec position(stream()) -> {{Line :: pos_integer(), Column :: pos_integer()}, stream()}.
```

Incremental lexing
```erlang
-spec slice(stream() | iodata(), OffsetStart :: non_neg_integer(), OffsetEnd :: non_neg_integer(),
           LineBase :: pos_integer(), ColumnBase :: pos_integer(), Opts :: list()) -> stream().

-spec relex_range(stream(), OffsetStart :: non_neg_integer(), OffsetEnd :: non_neg_integer(),
                 NewText :: iodata()) -> stream().
```
- `slice/6`: returns a stream over a byte range, rebasing metas to absolute (LineBase, ColumnBase).
- `relex_range/4`: invalidates buffered tokens overlapping the range, re-lexes just that slice, and splices results.

Terminator stack introspection and minimal insertion
```erlang
-spec current_terminators(stream()) -> {Terminators :: [{Start :: atom(), Meta :: term(), Indent :: non_neg_integer()}], stream()}.

%% Return only the next expected closer (top-of-stack), or nil
-spec peek_missing_terminator(stream()) -> {Closer :: atom() | nil, stream()}.
```
- Use `peek_missing_terminator/1` to perform minimal insertion decisions in the parser.
- When the parser asks the stream to insert a missing closer, the stream should emit the closer token with `{synthetic, true}` in `Extra` and proper ranged meta (end position equals start position for zero-width insertions).

Stability semantics (streaming rules)
- Tokens yielded by `next/1` are stable.
- In `embed` EOL mode, no standalone `eol` tokens are exposed; EOL information is carried in metas, avoiding retroactive mutation.
- Space-sensitive rewrites (`identifier` -> `op_identifier`), `not in` merge, and `do` rebinding happen inside the buffer before exposure.
- Linearization markers are emitted as-is; no nested containers are exposed.

Error handling (tolerant mode)
- On lexical error, the stream emits `{error_token, Meta, Reason}` and then advances to a synchronization point based on `{error_sync, …}`:
  - `semicolon`: up to and including the next `';'`
  - `newline`: up to the next newline boundary
  - `closer`: up to the next matching closer according to the current terminator stack
- After synchronization, streaming resumes. Multiple errors can be produced in one session.
- In `strict` mode, the first error causes `{eof, Stream1}` with an internal sticky error; callers can inspect the last error separately if needed.

Linearization and unescaping
- With `{linearize, true}` (forced), strings, sigils, heredocs, quoted atoms/keywords/identifiers, and interpolations are always flattened.
- `unescape=true` performs unescape before emitting fragments; errors surface as `{error_token, …}` in tolerant mode and stop in strict mode.

Example usage (Pratt sketch)
```erlang
{Tok, S1} = case toxic_stream:peek(S0) of
  {error_token, Sx} -> toxic_stream:next(Sx);  %% consume and continue
  Other -> Other
end,
{Left, S2} = nud(Tok, S1),
loop_infix(Left, S2, 0).
```

Implementation notes
- Internals maintain a small lookahead buffer (configurable); refill calls the existing tokenizer in bounded slices while preserving `Scope` (including terminators).
- Error synchronization is implemented purely at the lexer-stream layer; the core tokenization routines remain unchanged apart from returning sufficient metadata.
- Synthetic insertions use the same token constructors, setting `{synthetic, true}` in `Extra`.
