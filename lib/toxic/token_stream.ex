defmodule Toxic.TokenStream do
  @moduledoc """
  Streaming tokenizer for Pratt parsers (Elixir API).

  Provides a streaming interface over the tokenizer implemented in Erlang with:
  - Always ranged metas: `{{start_line, start_column}, {end_line, end_column}, extra}` with exclusive end
  - Always linearized output: no nested container tokens
  - Tolerant error recovery
  - Lookahead, pushback, and incremental lexing support
  """

  @typedoc "Token with ranged meta; shapes match tokenizer"
  # TODO: better typespec with detailed types
  @type token :: tuple()

  @typedoc "Lexer/process options"
  @type options :: [
          {:unescape, boolean()}
          | {:max_batch, non_neg_integer()}
          | {:error_mode, :tolerant | :strict}
          | {:error_sync, [:semicolon | :newline | :closer | :comma]}
          | {:error_max_skip, non_neg_integer()}
          | {:insert_structural_closers, boolean()}
          | {:insert_identifier_sanitization, boolean()}
          | {:preserve_comments, false | (integer(), integer(), list(), list(), list() -> any())}
          | {:existing_atoms_only, boolean()}
        ]

  @typedoc "Stream handle"
  @type t :: %__MODULE__{
          # Buffer holds entries of {token, pre_terms, pre_pos}
          buffer:
            :queue.queue({
              token,
              [{atom(), term(), non_neg_integer()}] | nil,
              {pos_integer(), pos_integer()} | nil
            }),
          # Push stack holds same entry shape for accurate state when pushing back
          push: [
            {
              token,
              [{atom(), term(), non_neg_integer()}] | nil,
              {pos_integer(), pos_integer()} | nil
            }
          ],
          driver: Toxic.Driver.t(),
          opts: options,
          eof: boolean(),
          error: term() | nil,
          # Track the last emitted entry to support precise pushback
          last_emitted_entry:
            {
              token,
              [{atom(), term(), non_neg_integer()}] | nil,
              {pos_integer(), pos_integer()} | nil
            }
            | nil
        }

  # TODO: Make sure it actually works with binary, iolist and producer function
  @typedoc "Source can be a binary or a producer function"
  @type source ::
          iodata() | (non_neg_integer(), non_neg_integer() -> {:more, binary()} | :eof)

  @type error() :: any()

  defstruct buffer: :queue.new(),
            push: [],
            driver: nil,
            source: nil,
            opts: [],
            eof: false,
            error: nil,
            last_emitted_entry: nil

  # Default options
  @default_opts [
    unescape: true,
    max_batch: 256,
    error_mode: :tolerant,
    error_sync: [:semicolon, :newline, :closer, :comma],
    error_max_skip: 4096,
    insert_structural_closers: true,
    insert_identifier_sanitization: true,
    elixir_compatibility: false,
    preserve_comments: false,
    existing_atoms_only: false
  ]

  @doc """
  Create a new token stream from source.

  ## Options
  - `:unescape` - Whether to unescape string contents (default: true)
  - `:max_batch` - Maximum tokens to fetch in one batch (default: 256)
  - `:error_mode` - Error handling: `:tolerant` or `:strict` (default: :tolerant)
  - `:error_sync` - Sync points for error recovery (default: [:semicolon, :newline, :closer])
  """
  # TODO: document options
  @spec new(iodata() | source(), pos_integer(), pos_integer(), options()) :: t()
  def new(source, line \\ 1, column \\ 1, opts \\ []) do
    opts =
      Keyword.merge(@default_opts, opts)
      |> Keyword.merge(line: line, column: column)

    driver = Toxic.Driver.new(opts)

    %__MODULE__{
      driver: driver,
      source: source,
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
            case Keyword.get(stream.opts, :error_mode, :tolerant) do
              :strict -> {:error, stream.error, stream}
              :tolerant -> recover_next(stream)
            end

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
            case Keyword.get(stream.opts, :error_mode, :tolerant) do
              :strict ->
                {:error, stream.error, stream}

              :tolerant ->
                stream = recover_into_buffer(stream)
                peek(stream)
            end

          true ->
            stream = refill_buffer(stream)
            peek(stream)
        end
    end
  end

  @doc """
  Peek at the next N tokens without consuming them.

  Returns `{:ok, tokens, stream}` or `{:eof, stream}`.
  """
  @spec(
    peek_n(t(), pos_integer()) :: {:ok, [token()], t()} | {:eof, [token()], t()},
    {:error, error(), [token()], t()}
  )
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
        # Try to recover/fill further in tolerant mode
        case Keyword.get(stream.opts, :error_mode, :tolerant) do
          :strict ->
            if stream.eof do
              {:eof, push_tokens ++ buffer_tokens, stream}
            else
              {:error, stream.error, push_tokens ++ buffer_tokens, stream}
            end

          :tolerant ->
            stream = fill_for_peek(stream, not_filled)

            new_buf_tokens =
              stream.buffer
              |> :queue.to_list()
              |> Enum.take(needed)
              |> Enum.map(fn {t, _, _} -> t end)

            new_not_filled = needed - length(new_buf_tokens)

            cond do
              new_not_filled == 0 -> {:ok, push_tokens ++ new_buf_tokens, stream}
              stream.eof -> {:eof, push_tokens ++ new_buf_tokens, stream}
              true -> {:ok, push_tokens ++ new_buf_tokens, stream}
            end
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
  Create a checkpoint for backtracking. Returns a reference identifying stream state.
  Uses process dictionary for storage
  """
  @spec checkpoint(t()) :: {reference(), t()}
  def checkpoint(%__MODULE__{} = stream) do
    ref = make_ref()
    # Store current state in process dictionary for simplicity
    # In production, might want a different approach
    Process.put(
      {__MODULE__, :checkpoint, ref},
      {stream.push, stream.buffer, stream.driver, stream.error, stream.eof,
       stream.last_emitted_entry}
    )

    {ref, stream}
  end

  @doc """
  Rewind to a previously created checkpoint identified by `ref`. Unless `delete_checkpoint?`
  flag is set to `false`, the function will free the process dictionary storage and invalidate the reference.
  """
  @spec rewind_to(t(), reference(), boolean()) :: t()
  def rewind_to(%__MODULE__{} = stream, ref, delete_checkpoint? \\ true) do
    case Process.get({__MODULE__, :checkpoint, ref}) do
      {push, buffer, driver, error, eof, last_emitted_entry} ->
        if delete_checkpoint? do
          Process.delete({__MODULE__, :checkpoint, ref})
        end

        %{
          stream
          | push: push,
            buffer: buffer,
            driver: driver,
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
  """
  # TODO: better docs
  @spec slice(
          t() | iodata(),
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
  #   # TODO: real implementation
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
  """
  @spec current_terminators(t()) :: {[{atom(), term(), non_neg_integer()}], t()}
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

      stream = Toxic.TokenStream.new("'hello'", 1, 1)
      {tokens, stream} = collect_all_tokens(stream)
      {warnings, stream} = Toxic.TokenStream.warnings(stream)
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
  Collect all error tokens emitted so far (for editor integrations).

  Returns a list of `{meta, %Toxic.Error{}}` entries.
  """
  @type error_entry :: {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}, any()}
  @spec errors(t()) :: {[{error_entry(), Toxic.Error.t()}], t()}
  def errors(%__MODULE__{} = stream) do
    tokens = to_stream(stream) |> Enum.to_list()

    errs =
      tokens
      |> Enum.flat_map(fn
        {:error_token, meta, %Toxic.Error{} = err} -> [{meta, err}]
        _ -> []
      end)

    {errs, stream}
  end

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

  defp normalize_source_for_driver(source) when is_binary(source), do: String.to_charlist(source)
  defp normalize_source_for_driver(source) when is_list(source), do: source

  # TODO: no coverage
  defp normalize_source_for_driver(source) when is_function(source, 2) do
    # For function sources, convert to charlist on each call
    fn line, column ->
      case source.(line, column) do
        {:more, binary} -> {:more, String.to_charlist(binary)}
        :eof -> :eof
      end
    end
  end

  defp fetch_tokens_from_driver(stream, max_batch, opts) do
    # Fetch a batch from the Erlang driver, then optionally collapse linear markers
    # TODO: slicing source
    source_string = normalize_source_for_driver(stream.source)

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
        cond do
          strict_error?(stream) ->
            {{stream.driver.line, stream.driver.column}, stream}

          Keyword.get(stream.opts, :error_mode, :tolerant) == :tolerant and stream.error ->
            stream = recover_into_buffer(stream)
            position(stream)

          true ->
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

      stream.error && Keyword.get(stream.opts, :error_mode, :tolerant) == :tolerant ->
        stream
        |> recover_into_buffer()
        |> ensure_buffer_size(needed)

      true ->
        stream
        |> refill_buffer()
        |> ensure_buffer_size(needed)
    end
  end

  # Attempt to fill buffer with at least count more tokens in tolerant mode
  defp fill_for_peek(%__MODULE__{} = stream, count, tries \\ 0) do
    cond do
      tries > 4 -> stream
      stream.eof -> stream
      stream.error -> fill_for_peek(recover_into_buffer(stream), count, tries + 1)
      true -> fill_for_peek(refill_buffer(stream), count, tries + 1)
    end
  end

  defp recover_next(%__MODULE__{} = stream) do
    # Recover one error token directly and return it
    pre_terms = Toxic.Driver.current_terminators(stream.driver)

    case Toxic.Driver.recover(stream.source, stream.driver, stream.error) do
      {:ok, token, new_source, new_driver} ->
        pre_pos = start_pos(token)
        entry = {token, pre_terms, pre_pos}

        new_stream =
          %{
            stream
            | driver: new_driver,
              source: new_source,
              error: nil,
              last_emitted_entry: entry
          }

        {:ok, token, new_stream}

      other ->
        other
    end
  end

  defp recover_into_buffer(%__MODULE__{} = stream) do
    pre_terms = Toxic.Driver.current_terminators(stream.driver)

    case Toxic.Driver.recover(stream.source, stream.driver, stream.error) do
      {:ok, token, new_source, new_driver} ->
        pre_pos = start_pos(token)
        entry = {token, pre_terms, pre_pos}
        new_buffer = :queue.in(entry, stream.buffer)
        %{stream | driver: new_driver, source: new_source, error: nil, buffer: new_buffer}

      _ ->
        stream
    end
  end

  defp extract_slice(source, start_offset, end_offset) when is_binary(source) do
    # TODO: this should use String.slice to handle unicode
    binary_part(source, start_offset, end_offset - start_offset)
  end

  # TODO: no coverage
  defp extract_slice(source, start_offset, end_offset) when is_function(source, 2) do
    # For function sources, we'd need to call it appropriately
    # This is a simplified implementation
    fn _line, _column ->
      case source.(start_offset, end_offset - start_offset) do
        {:more, binary} -> {:more, binary}
        _ -> :eof
      end
    end
  end

  defp strict_error?(%__MODULE__{error: error, opts: opts}) do
    error != nil and Keyword.get(opts, :error_mode, :tolerant) == :strict
  end
end
