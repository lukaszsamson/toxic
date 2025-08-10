### Toxic.TokenStream (Elixir API)

An Elixir-first streaming tokenizer interface designed for Pratt parsers. It wraps the Erlang tokenizer, but only exposes ranged, linearized tokens and supports tolerant error recovery, lookahead, pushback, and incremental lexing.

Design constraints
- Always ranged metas: `{{start_line, start_column}, {end_line, end_column}, extra}` with exclusive end.
- Always linearized output: no nested container tokens; strings, heredocs, sigils, quoted identifiers/atoms/keywords are emitted as begin/end markers plus fragments/interpolations.
- Optional tolerant error mode emits error tokens and resumes at synchronization points.

Module
- `Toxic.TokenStream`

Types (dialyzer/specs)
```elixir
defmodule Toxic.TokenStream do
  @moduledoc """
  Streaming tokenizer for Pratt parsers (Elixir API).
  """

  @typedoc "Token with ranged meta; shapes match Erlang tokenizer"
  @type token :: tuple()

  @typedoc "Lexer/process options"
  @type options :: [
          {:unescape, boolean()} |
          {:max_batch, non_neg_integer()} |
          {:eol_mode, :embed | :emit} |
          {:error_mode, :tolerant | :strict} |
          {:error_sync, [:semicolon | :newline | :closer]}
        ]

  @typedoc "Opaque stream handle"
  @type t :: %__MODULE__{
          buffer: :queue.queue(token),
          push: [token],
          state: term(),           # driver state (offsets, ranges, terminators, etc.)
          opts: options,
          source: source()
        }
  defstruct [:buffer, :push, :state, :opts, :source]

  @typedoc "Source can be a binary or a producer function"
  @type source :: iodata() | ( (non_neg_integer(), non_neg_integer()) -> {:more, binary()} | :eof )
end
```

Token shapes (subset; always linearized)
- Strings/charlists
  - `{bin_string_start | list_string_start, meta, quote}` … `{string_fragment, frag_meta, binary}` … `{bin_string_end | list_string_end, meta, quote}`
- Heredocs
  - `{bin_heredoc_start | list_heredoc_start, meta, "\"\"\""|"'''"}` … `{string_fragment, …}` … `{bin_heredoc_end | list_heredoc_end, meta, delim, indent}`
- Sigils
  - `{sigil_start, meta, sigil_atom, delim}` … `{string_fragment, …}` … `{sigil_end, meta, sigil_atom, delim, indent}` [optional `{sigil_modifiers, meta, mods}`]
- Interpolation
  - `{begin_interpolation, meta, kind}` … inner tokens … `{end_interpolation, meta, kind}`
- Quoted keyword identifiers
  - `{kw_identifier_unsafe_start, meta, quote}` … fragments/interpol … `{kw_identifier_unsafe_end, meta, quote}`, followed by `{:':', meta}`
- Quoted atoms
  - `{atom_safe_start | atom_unsafe_start, meta, quote}` … fragments/interpol … `{atom_safe_end | atom_unsafe_end, meta, quote}`
- Quoted calls (identifier inside quotes)
  - `{quoted_identifier_start, meta, quote}` … `{paren_identifier | bracket_identifier | identifier, meta, atom}` … `{quoted_identifier_end, meta, quote}`
- Error token (tolerant mode)
  - `{error_token, meta, reason}`
- Synthetic insertions (minimal delimiters)
  - Marked by `{:synthetic, true}` inside meta extra; zero-width ranges allowed

Construction
```elixir
@spec new(iodata(), pos_integer(), pos_integer(), options()) :: t()
@spec new(( (non_neg_integer(), non_neg_integer()) -> {:more, binary()} | :eof ), pos_integer(), pos_integer(), options()) :: t()
```
- Options:
  - `:unescape` (default true)
  - `:max_batch` (default 256)
  - `:eol_mode` (default :embed)
  - `:error_mode` (default :tolerant)
  - `:error_sync` (default [:semicolon, :newline, :closer])
- `produce_ranges: true` and `linearize: true` are always enforced by the wrapper.

Core API (Pratt-friendly)
```elixir
@spec next(t()) :: {:ok, token(), t()} | {:eof, t()}
@spec peek(t()) :: {:ok, token(), t()} | {:eof, t()}
@spec peek_n(t(), pos_integer()) :: {:ok, [token()], t()} | {:eof, t()}
@spec pushback(t(), token()) :: t()

# Backtracking
@spec checkpoint(t()) :: {reference(), t()}
@spec rewind_to(t(), reference()) :: t()

# Current absolute position (start of next token)
@spec position(t()) :: {{pos_integer(), pos_integer()}, t()}
```

Enumerable view (optional)
- `to_stream/1` returns an Elixir `Stream.resource/3` for simple consumers that do not need pushback.
```elixir
@spec to_stream(t()) :: Enumerable.t()
```

Incremental lexing
```elixir
@spec slice(t() | iodata(), non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer(), options()) :: t()
@spec relex_range(t(), non_neg_integer(), non_neg_integer(), iodata()) :: t()
```
- `slice/6` rebases returned token ranges to absolute `(line_base, column_base)`.
- `relex_range/4` invalidates buffered tokens overlapping the range and splices in freshly lexed tokens for that slice.

Terminator stack introspection & minimal insertion
```elixir
@spec current_terminators(t()) :: {[{atom(), term(), non_neg_integer()}], t()}
@spec peek_missing_terminator(t()) :: {atom() | nil, t()}
```
- The parser can request a synthetic closer token; the stream will emit it tagged with `{:synthetic, true}` in meta extra.

Stability semantics
- Tokens returned from `next/1` are stable.
- In `:embed` EOL mode, no standalone `{:eol, meta}` tokens are exposed; EOL counts are embedded in token metas when relevant.
- Space-sensitive rewrites (`identifier` → `op_identifier`), `not in` merge, and `do` rebinding happen inside the buffer before exposure.
- Only linear markers/fragments are exposed; never nested containers.

Error handling (tolerant mode)
- On a lexical error, the stream emits `{error_token, meta, reason}` and advances to the next sync point per `:error_sync`.
- In `:strict` mode, the first error transitions the stream to `{ :eof, stream }` with internal sticky error (can be inspected via a debug API if needed).

Examples
```elixir
{:ok, tok, s1} = Toxic.TokenStream.next(s0)
{:ok, look, s2} = Toxic.TokenStream.peek(s1)
# Decide prefix vs infix with Pratt lbp/nud/led

# Pushback on backtrack
s3 = Toxic.TokenStream.pushback(s2, look)

# Minimal delimiter insertion
{closer, s4} = Toxic.TokenStream.peek_missing_terminator(s3)
if closer == :')' do
  # request stream to insert synthetic closer
  {:ok, tok, s5} = Toxic.TokenStream.next(s4)
  # tok will be {')', meta} with {:synthetic, true} in meta extra
end

# Streaming over tokens (no pushback)
Toxic.TokenStream.to_stream(s0)
|> Stream.take(100)
|> Enum.to_list()
```

Implementation (sketch)
- The Elixir module delegates to the Erlang tokenizer with `produce_ranges: true` and `linearize: true` enforced.
- Maintains a small lookahead queue and a pushback stack; refills in batches (`:max_batch`).
- Applies EOL normalization and space-sensitive rewrites in-buffer pre-exposure.
- Emits `{error_token, meta, reason}` and performs sync skipping per `:error_sync` in tolerant mode.
