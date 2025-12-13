defmodule Toxic do
  @moduledoc """
  Streaming tokenizer for Pratt parsers.

  Provides a streaming interface over the tokenizer implemented in Elixir with:
  - Always ranged metas: `{{start_line, start_column}, {end_line, end_column}, extra}` with exclusive end
  - Always linearized output: no nested container tokens
  - Tolerant error recovery
  - Lookahead, pushback, and incremental lexing support
  """

  @typedoc """
  Token metadata with ranged position information.

  Format: `{{start_line, start_column}, {end_line, end_column}, extra}`
  - Line and column are 1-based
  - End position is exclusive
  - Extra can be `nil` or contain token-specific information
  """
  @type meta :: {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}, term()}

  @typedoc """
  Token with ranged meta.

  All tokens follow one of these shapes:
  - `{atom(), meta()}` - Simple tokens like delimiters
  - `{atom(), meta(), term()}` - Tokens with a value (identifiers, literals, etc.)
  - `{atom(), meta(), term(), term()}` - Special tokens like sigils with multiple attributes

  Where `meta()` is `{{start_line, start_column}, {end_line, end_column}, extra}`
  with 1-based line/column positions and exclusive end positions.
  """
  @type token ::
          {atom(), meta()}
          | {atom(), meta(), term()}
          | {atom(), meta(), term(), term()}

  @typedoc "Lexer/process options"
  @type options :: [
          {:unescape, boolean()}
          | {:max_batch, non_neg_integer()}
          | {:error_mode, :tolerant | :strict}
          | {:error_sync, [:semicolon | :newline | :closer | :comma | :comment | :whitespace]}
          | {:error_max_skip, non_neg_integer()}
          | {:insert_structural_closers, boolean()}
          | {:insert_identifier_sanitization, boolean()}
          | {:error_token_payload, :struct | :tuple | :both}
          | {:preserve_comments, false | (integer(), integer(), list(), list(), list() -> any())}
          | {:existing_atoms_only, boolean()}
          | {:static_atoms_encoder,
             nil | (binary(), keyword() -> {:ok, term()} | {:error, binary()})}
        ]

  @typedoc """
  Internal buffer entry.

  Each buffered token is stored with:
  - `token` - The token itself
  - `pre_terms` - Terminator stack snapshot before this token (nil if not captured)
  - `pre_pos` - Position before this token (nil if not captured)
  """
  @type buffer_entry :: {
          token(),
          terminator_stack() | nil,
          position() | nil
        }

  @typedoc "Terminator stack entry: `{delimiter_atom, meta, indentation}`"
  @type terminator_entry :: {atom(), term(), non_neg_integer()}

  @typedoc "Stack of open terminators (delimiters, do/end blocks, etc.)"
  @type terminator_stack :: [terminator_entry()]

  @typedoc "Line and column position (1-based)"
  @type position :: {pos_integer(), pos_integer()}

  @typedoc "Stream handle"
  @type t :: %__MODULE__{
          buffer: :queue.queue(buffer_entry()),
          push: [buffer_entry()],
          driver: Toxic.Driver.t(),
          opts: options(),
          eof: boolean(),
          error: Toxic.Error.t() | nil,
          last_emitted_entry: buffer_entry() | nil,
          driver_source: charlist() | nil,
          source_binary: binary() | nil
        }

  @typedoc """
  Source type accepted by `new/4`:
  - UTF-8 binary
  - Flat charlist (list of codepoints/bytes)

  """
  @type source :: binary() | charlist()

  @typedoc """
  Error value.

  Can be either a structured `Toxic.Error` or a legacy error tuple/charlist.
  """
  @type error :: Toxic.Error.t()

  defstruct buffer: :queue.new(),
            push: [],
            driver: nil,
            source: nil,
            opts: [],
            eof: false,
            error: nil,
            last_emitted_entry: nil,
            driver_source: nil,
            source_binary: nil

  # Default options
  @default_opts [
    unescape: true,
    max_batch: 256,
    error_mode: :tolerant,
    error_sync: [:semicolon, :newline, :closer, :comma, :comment, :whitespace],
    error_max_skip: 4096,
    insert_structural_closers: true,
    insert_identifier_sanitization: true,
    error_token_payload: :struct,
    elixir_compatibility: false,
    preserve_comments: false,
    existing_atoms_only: false,
    static_atoms_encoder: nil
  ]

  @doc """
  Create a new token stream from source.

  ## Parameters
  - `source` - Binary or flat charlist
  - `line` - Starting line number (default: 1)
  - `column` - Starting column number (default: 1)
  - `opts` - Keyword list of options

  ## Options
  - `:unescape` - Whether to unescape string contents (default: `true`)
  - `:max_batch` - Maximum tokens to fetch in one batch (default: `256`)
  - `:error_mode` - Error handling: `:tolerant` or `:strict` (default: `:tolerant`)
  - `:error_sync` - Sync points for error recovery (default: `[:semicolon, :newline, :closer, :comma]`)
  - `:error_max_skip` - Maximum characters to skip during error recovery (default: `4096`)
  - `:insert_structural_closers` - Synthesize missing delimiters in tolerant mode (default: `true`)
  - `:insert_identifier_sanitization` - Sanitize invalid identifiers in tolerant mode (default: `true`)
  - `:preserve_comments` - Whether to preserve comments (default: `false`)
  - `:existing_atoms_only` - Only allow existing atoms in keywords (default: `false`)
  - `:static_atoms_encoder` - Optional callback invoked whenever the tokenizer needs to create a *static* atom.
    Receives `(value_binary, [line: line, column: column])` and must return `{:ok, term}` or `{:error, reason_binary}` (default: `nil`).
    When set, this overrides `:existing_atoms_only` for static atoms; `:existing_atoms_only` is still used for dynamic atoms (for example atoms created at runtime via interpolation).

  ## Examples

      iex> stream = Toxic.new("1 + 2")
      iex> {:ok, token, _} = Toxic.next(stream)
      iex> token
      {:int, {{1, 1}, {1, 2}, 1}, ~c"1"}

  """
  @spec new(source(), pos_integer(), pos_integer(), options()) :: t()
  def new(source, line \\ 1, column \\ 1, opts \\ []) do
    opts =
      Keyword.merge(@default_opts, opts)
      |> Keyword.merge(line: line, column: column)

    driver = Toxic.Driver.new(opts)

    {driver_source, source_binary, effective_source} =
      cond do
        is_binary(source) ->
          charlist = String.to_charlist(source)
          {charlist, source, charlist}

        is_list(source) ->
          bin = :unicode.characters_to_binary(source)
          {source, bin, source}

        true ->
          raise ArgumentError,
                "Unsupported source type: #{inspect(source)}. Expected binary or flat charlist"
      end

    %__MODULE__{
      driver: driver,
      source: effective_source,
      driver_source: driver_source,
      source_binary: source_binary,
      opts: opts
    }
  end

  @doc """
  Get the next token from the stream.

  Returns `{:ok, token, stream}` or `{:eof, stream}`.
  """
  @spec next(t()) :: {:ok, token(), t()} | {:eof, t()} | {:error, error(), t()}
  def next(%__MODULE__{push: [{token, _pre_terms, _pre_pos} | rest]} = stream) do
    {:ok, token, %{stream | push: rest}}
  end

  def next(%__MODULE__{buffer: buffer} = stream) do
    case :queue.out(buffer) do
      {{:value, {token, _pre_terms, _pre_pos} = entry}, new_buffer} ->
        # Update last emitted entry for accurate pushback semantics
        stream = %{stream | buffer: new_buffer, last_emitted_entry: entry}

        {:ok, token, stream}

      {:empty, _} ->
        cond do
          stream.eof ->
            {:eof, stream}

          stream.error ->
            {:error, stream.error, stream}

          true ->
            stream = refill_buffer(stream)
            next(stream)
        end
    end
  end

  @doc """
  Peek at the next token without consuming it.

  Returns `{:ok, token, stream}` or `{:eof, stream}`.
  """
  @spec peek(t()) :: {:ok, token(), t()} | {:eof, t()} | {:error, error(), t()}
  def peek(%__MODULE__{push: [{token, _, _} | _]} = stream) do
    {:ok, token, stream}
  end

  def peek(%__MODULE__{buffer: buffer} = stream) do
    case :queue.peek(buffer) do
      {:value, {token, _pre_terms, _pre_pos}} ->
        {:ok, token, stream}

      :empty ->
        cond do
          stream.eof ->
            {:eof, stream}

          stream.error ->
            {:error, stream.error, stream}

          true ->
            stream = refill_buffer(stream)
            peek(stream)
        end
    end
  end

  @doc """
  Peek at the next N tokens without consuming them.

  Returns a tuple indicating success, EOF, or error, along with the tokens
  available (which may be fewer than N at EOF or in strict error mode).

  ## Returns
  - `{:ok, tokens, stream}` - Successfully peeked N tokens
  - `{:eof, tokens, stream}` - Reached EOF; tokens contains all available tokens (< N)
  - `{:error, error, tokens, stream}` - Error in strict mode; tokens contains tokens before error

  ## Examples

      iex> stream = Toxic.new("1 + 2")
      iex> {:ok, tokens, _} = Toxic.peek_n(stream, 2)
      iex> length(tokens)
      2

  """
  @spec peek_n(t(), pos_integer()) ::
          {:ok, [token()], t()} | {:eof, [token()], t()} | {:error, error(), [token()], t()}
  def peek_n(_stream, n) when n <= 0 do
    raise ArgumentError, message: "n must be positive"
  end

  def peek_n(%__MODULE__{} = stream, n) do
    push_tokens =
      stream.push
      |> Enum.take(n)
      |> Enum.map(fn {t, _, _} -> t end)

    needed = n - length(push_tokens)

    if needed == 0 do
      {:ok, push_tokens, stream}
    else
      stream = ensure_buffer_size(stream, needed)

      buffer_tokens =
        stream.buffer
        |> :queue.to_list()
        |> Enum.take(needed)
        |> Enum.map(fn {t, _, _} -> t end)

      not_filled = needed - length(buffer_tokens)

      if not_filled == 0 do
        {:ok, push_tokens ++ buffer_tokens, stream}
      else
        # If ensure_buffer_size didn't fill enough, we're either at EOF or have an error
        if stream.eof do
          {:eof, push_tokens ++ buffer_tokens, stream}
        else
          # In strict mode with error, return error tuple
          {:error, stream.error, push_tokens ++ buffer_tokens, stream}
        end
      end
    end
  end

  @doc """
  Push a token back onto the stream.
  """
  @spec pushback(t(), token()) :: t()
  def pushback(%__MODULE__{push: push, last_emitted_entry: last} = stream, token) do
    entry =
      case last do
        {^token, _pre_terms, _pre_pos} = entry -> entry
        _ -> {token, nil, nil}
      end

    %{stream | push: [entry | push]}
  end

  @doc """
  Create a checkpoint for backtracking.

  Saves the current stream state (buffer, push stack, driver state) and returns
  a reference that can be used with `rewind_to/2` to restore this state later.

  The checkpoint is stored in the process dictionary for simplicity. In production
  use cases, you may want to implement a different storage mechanism.

  ## Returns
  A tuple `{reference, stream}` where the reference can be passed to `rewind_to/2`.

  ## Examples

      stream = Toxic.new("1 + 2 * 3")
      {:ok, _token1, stream} = Toxic.next(stream)
      {ref, stream} = Toxic.checkpoint(stream)
      {:ok, _token2, stream} = Toxic.next(stream)
      stream = Toxic.rewind_to(stream, ref)  # Back to position after token1

  """
  @spec checkpoint(t()) :: {reference(), t()}
  def checkpoint(%__MODULE__{} = stream) do
    ref = make_ref()
    # Store current state in process dictionary for simplicity
    # In production, might want a different approach
    Process.put(
      {__MODULE__, :checkpoint, ref},
      {stream.push, stream.buffer, stream.driver, stream.error, stream.eof,
       stream.last_emitted_entry, stream.source, stream.driver_source}
    )

    {ref, stream}
  end

  @doc """
  Rewind to a previously created checkpoint.

  Restores the stream state (buffer, push stack, driver) to the state captured
  when `checkpoint/1` was called with the given reference.

  ## Parameters
  - `stream` - Current stream
  - `ref` - Reference returned from `checkpoint/1`
  - `delete_checkpoint?` - Whether to free checkpoint storage (default: `true`)

  ## Returns
  Updated stream at the checkpoint state.

  ## Raises
  `ArgumentError` if the reference is invalid or not found.

  """
  @spec rewind_to(t(), reference(), boolean()) :: t()
  def rewind_to(%__MODULE__{} = stream, ref, delete_checkpoint? \\ true) do
    case Process.get({__MODULE__, :checkpoint, ref}) do
      {push, buffer, driver, error, eof, last_emitted_entry, source, driver_source} ->
        if delete_checkpoint? do
          Process.delete({__MODULE__, :checkpoint, ref})
        end

        %{
          stream
          | push: push,
            buffer: buffer,
            driver: driver,
            source: source,
            driver_source: driver_source,
            error: error,
            eof: eof,
            last_emitted_entry: last_emitted_entry
        }

      nil ->
        raise ArgumentError, "Invalid checkpoint reference"
    end
  end

  @doc """
  Convert the stream to an Elixir Stream for enumeration.
  """
  @spec to_stream(t()) :: Enumerable.t()
  def to_stream(%__MODULE__{} = stream) do
    Stream.resource(
      fn -> stream end,
      fn stream ->
        case next(stream) do
          {:ok, token, new_stream} ->
            {[token], new_stream}

          {:eof, new_stream} ->
            {:halt, new_stream}

          {:error, _error, new_stream} ->
            # TODO: is it ok to halt instead of erroring?
            {:halt, new_stream}
        end
      end,
      fn _stream -> :ok end
    )
  end

  @doc """
  Create a stream from a slice of input.

  Useful for incremental lexing when you need to tokenize a substring
  with adjusted base position for accurate error reporting.

  ## Parameters
  - `source` - Original source (binary or existing stream)
  - `start_offset` - Byte offset where slice begins
  - `end_offset` - Byte offset where slice ends (exclusive)
  - `line_base` - Line number to use for first token
  - `column_base` - Column number to use for first token
  - `opts` - Options (same as `new/4`)

  ## Returns
  A new stream starting at the specified position.

  ## Notes
  - Currently uses `binary_part/3` which doesn't handle Unicode graphemes
  - Future versions may use `String.slice/3` for proper Unicode support

  """
  @spec slice(
          t() | binary() | charlist(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          options()
        ) :: t()
  def slice(source, start_offset, end_offset, line_base, column_base, opts \\ []) do
    slice_source = extract_slice(source, start_offset, end_offset)
    new(slice_source, line_base, column_base, opts)
  end

  # TODO: implement
  # @doc """
  # Re-lex a range of the input.
  # """
  # @spec relex_range(t(), non_neg_integer(), non_neg_integer(), iodata()) :: t()
  # def relex_range(%__MODULE__{} = stream, _start_offset, _end_offset, new_content) do
  #   # This is a complex operation that would require:
  #   # 1. Invalidating buffered tokens in the range
  #   # 2. Re-lexing the new content
  #   # 3. Splicing the results
  #   # For now, create a new stream with the new content
  #   {{line, column}, _} = position(stream)
  #   new(new_content, line, column, stream.opts)
  # end

  @doc """
  Get the current terminator stack.

  Returns the stack of open delimiters, blocks, and string contexts that need
  to be closed. Each entry is a tuple of `{opening_delimiter, meta, indentation}`.

  Useful for:
  - Auto-completion in editors
  - Syntax error recovery
  - Understanding parser context

  ## Returns
  A tuple `{terminators, stream}` where terminators is a list of terminator entries.

  ## Examples

      stream = Toxic.new("(1 + ")
      {:ok, _paren, stream} = Toxic.next(stream)
      {terms, _} = Toxic.current_terminators(stream)
      # terms will include {:\"(\", meta, indent}

  """
  @spec current_terminators(t()) :: {terminator_stack(), t()}
  def current_terminators(%__MODULE__{} = stream) do
    terms = terms_at_current_position(stream)
    {terms, stream}
  end

  @doc """
  Peek at a potentially missing terminator.
  """
  @spec peek_missing_terminator(t()) :: {atom() | nil, t()}
  def peek_missing_terminator(%__MODULE__{} = stream) do
    terms = terms_at_current_position(stream)

    closer =
      case terms do
        [{start, _meta, _indent} | _] -> Toxic.Driver.closing_for(start)
        _ -> nil
      end

    {closer, stream}
  end

  @doc """
  Get accumulated warnings from the tokenizer.

  Returns a list of structured warnings as `Toxic.Warning.t()` structs.
  Each warning contains:
  - `code`: Unique atom identifying the warning type
  - `domain`: Category grouping (e.g., :deprecated, :ambiguous, :escape, :unicode)
  - `token_display`: Visual representation of the problematic token
  - `details`: Map containing line, column, and other contextual information

  ## Example

      stream = Toxic.new("'hello'", 1, 1)
      {tokens, stream} = collect_all_tokens(stream)
      {warnings, stream} = Toxic.warnings(stream)
      # warnings = [
      #   %Toxic.Warning{
      #     code: :deprecated_single_quote_atom,
      #     domain: :deprecated,
      #     token_display: ~c":'atom'",
      #     details: %{line: 1, column: 1, suggestion: ...}
      #   }
      # ]
  """
  @spec warnings(t()) :: {[Toxic.Warning.t()], t()}
  def warnings(%__MODULE__{driver: driver} = stream) do
    require Toxic.Scope
    warnings = Toxic.Scope.scope(driver.scope, :warnings)
    {warnings, stream}
  end

  @doc """
  Collect error tokens without consuming the stream (for editor integrations).

  This scans the remaining tokens in the stream and returns a list of
  `{meta, %Toxic.Error{}}` entries while leaving the original stream unchanged.

  Supports all `:error_token` payload modes (`:struct`, `:tuple`, `:both`).
  """
  @type error_entry :: {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}, any()}
  @spec errors(t()) :: {[{error_entry(), Toxic.Error.t()}], t()}
  def errors(%__MODULE__{} = stream) do
    tokens = to_stream(stream) |> Enum.to_list()

    errs =
      tokens
      |> Enum.flat_map(fn
        {:error_token, meta, %Toxic.Error{} = err} -> [{meta, err}]
        {:error_token, meta, {%Toxic.Error{} = err, _tuple}} -> [{meta, err}]
        {:error_token, meta, payload} -> [{meta, Toxic.Error.ensure_struct(payload)}]
        _ -> []
      end)

    {errs, stream}
  end

  @doc """
  Converts a list of Toxic tokens back to a string.
  """
  defdelegate to_string(tokens), to: Toxic.ToString

  # Compute terms at the logical current position (before next token)
  defp terms_at_current_position(%__MODULE__{push: [{_tok, pre_terms, _} | _]})
       when is_list(pre_terms) do
    pre_terms
  end

  defp terms_at_current_position(%__MODULE__{buffer: buffer} = stream) do
    case :queue.peek(buffer) do
      {:value, {_token, pre_terms, _}} when is_list(pre_terms) ->
        pre_terms

      _ ->
        Toxic.Driver.current_terminators(stream.driver)
    end
  end

  # Extract start position from a ranged meta token
  defp start_pos({_, {{sl, sc}, _end_meta, _extra}, _rest1, _rest2}), do: {sl, sc}
  defp start_pos({_, {{sl, sc}, _end_meta, _extra}, _rest}), do: {sl, sc}
  defp start_pos({_, {{sl, sc}, _end_meta, _extra}}), do: {sl, sc}

  # Private functions

  defp fetch_tokens_from_driver(stream, max_batch, opts) do
    # Fetch a batch from the Erlang driver, then optionally collapse linear markers
    # source already normalized once in new/4 for binary/charlist inputs
    source_string = stream.source

    {tokens, source_string, new_driver, eof, error} =
      fetch_tokens_from_driver(stream.driver, source_string, max_batch, [], 0, opts)

    {tokens, source_string, new_driver, eof, error}
  end

  defp fetch_tokens_from_driver(driver, source_string, max_batch, acc, count, _opts)
       when count >= max_batch do
    {Enum.reverse(acc), source_string, driver, false, nil}
  end

  defp fetch_tokens_from_driver(driver, source_string, max_batch, acc, count, opts) do
    case Toxic.Driver.next(source_string, driver) do
      {:ok, token, new_source_string, new_driver} ->
        # Snapshot terminators and starting position of the token
        pre_terms = Toxic.Driver.current_terminators(driver)
        pre_pos = start_pos(token)

        # Accumulate entry as {token, pre_terms, pre_pos}
        fetch_tokens_from_driver(
          new_driver,
          new_source_string,
          max_batch,
          [{token, pre_terms, pre_pos} | acc],
          count + 1,
          opts
        )

      {:eof, driver} ->
        {Enum.reverse(acc), [], driver, true, nil}

      {:error, reason, rest_string, driver} ->
        # Propagate error; keep rest_string as the current source
        {Enum.reverse(acc), rest_string, driver, false, reason}
    end
  end

  defp refill_buffer(%__MODULE__{opts: opts, eof: false} = stream) do
    max_batch = Keyword.get(opts, :max_batch, 256)

    {tokens, source, new_driver, eof, error} = fetch_tokens_from_driver(stream, max_batch, opts)

    new_buffer =
      Enum.reduce(tokens, stream.buffer, fn entry, buf ->
        :queue.in(entry, buf)
      end)

    # Only mark EOF when the driver explicitly reports EOF.
    # Do not infer EOF from batch size; tolerant mode may need additional
    # driver cycles to drain pending errors and synthesized closers.
    stream_eof = if eof, do: true, else: stream.eof

    %{
      stream
      | buffer: new_buffer,
        driver: new_driver,
        source: source,
        driver_source: source,
        eof: stream_eof,
        error: stream.error || error
    }
  end

  @doc """
  Get the current absolute position (start of next token).
  Uses snapshot captured before the head token to avoid batch drift.
  """
  @spec position(t()) :: {{pos_integer(), pos_integer()}, t()}
  def position(%__MODULE__{} = stream) do
    cond do
      match?([{_, _, {_l, _c}} | _], stream.push) ->
        [{_, _, {l, c}} | _] = stream.push
        {{l, c}, stream}

      match?({:value, {_, _, {_l, _c}}}, :queue.peek(stream.buffer)) ->
        {:value, {_, _, {l, c}}} = :queue.peek(stream.buffer)
        {{l, c}, stream}

      stream.eof ->
        {{stream.driver.line, stream.driver.column}, stream}

      true ->
        # Ensure we have a head entry to accurately reflect the next-token start
        if strict_error?(stream) do
          {{stream.driver.line, stream.driver.column}, stream}
        else
          stream = refill_buffer(stream)
          position(stream)
        end
    end
  end

  defp ensure_buffer_size(%__MODULE__{} = stream, needed) do
    buffer_size = :queue.len(stream.buffer)

    cond do
      buffer_size >= needed or stream.eof ->
        stream

      stream.error ->
        # Driver reported an error; do not attempt to refill
        stream

      true ->
        stream
        |> refill_buffer()
        |> ensure_buffer_size(needed)
    end
  end

  defp extract_slice(source, start_offset, end_offset) when is_binary(source) do
    String.slice(source, start_offset, end_offset - start_offset)
  end

  defp extract_slice(source, start_offset, end_offset) when is_list(source) do
    # Convert once then slice using codepoint offsets (String.slice is codepoint-aware)
    bin = :unicode.characters_to_binary(source)
    String.slice(bin, start_offset, end_offset - start_offset)
  end

  defp extract_slice(%__MODULE__{source_binary: bin}, start_offset, end_offset)
       when is_integer(start_offset) and is_integer(end_offset) do
    if bin do
      String.slice(bin, start_offset, end_offset - start_offset)
    else
      ""
    end
  end

  defp strict_error?(%__MODULE__{error: error, opts: opts}) do
    error != nil and Keyword.get(opts, :error_mode, :tolerant) == :strict
  end
end
