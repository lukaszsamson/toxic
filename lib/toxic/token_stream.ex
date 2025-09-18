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
          | {:eol_mode, :embed | :emit}
          | {:error_mode, :tolerant | :strict}
          | {:error_sync, [:semicolon | :newline | :closer]}
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
    eol_mode: :emit,
    error_mode: :tolerant,
    error_sync: [:semicolon, :newline, :closer],
    elixir_compatibility: false,
    preserve_comments: false,
    existing_atoms_only: false
  ]

  @doc """
  Create a new token stream from source.

  ## Options
  - `:unescape` - Whether to unescape string contents (default: true)
  - `:max_batch` - Maximum tokens to fetch in one batch (default: 256)
  - `:eol_mode` - How to handle EOL tokens: `:embed` or `:emit` (default: :emit)
  - `:error_mode` - Error handling: `:tolerant` or `:strict` (default: :tolerant)
  - `:error_sync` - Sync points for error recovery (default: [:semicolon, :newline, :closer])
  """
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
  @spec next(t()) :: {:ok, token(), t()} | {:eof, t()}
  def next(%__MODULE__{eof: true, push: [], buffer: buffer} = stream) do
    case :queue.is_empty(buffer) do
      true -> {:eof, stream}
      # Still have tokens in buffer
      false -> do_next(stream)
    end
  end

  def next(%__MODULE__{eof: true, push: [_ | _]} = stream) do
    # EOF but still have pushed tokens
    do_next(stream)
  end

  def next(%__MODULE__{error: error, opts: opts} = stream) when error != nil do
    # Check if we have buffered or pushed tokens to return first
    if has_buffered_tokens?(stream) do
      do_next(stream)  # Return buffered tokens first
    else
      # Only return error when no more buffered tokens
      if Keyword.get(opts, :error_mode, :tolerant) == :strict do
        {:error, error, stream}
      else
        do_next(stream)
      end
    end
  end

  def next(%__MODULE__{} = stream) do
    do_next(stream)
  end

  defp do_next(%__MODULE__{push: [{token, _pre_terms, _pre_pos} | rest]} = stream) do
    {:ok, token, %{stream | push: rest}}
  end

  defp do_next(%__MODULE__{buffer: buffer} = stream) do
    case :queue.out(buffer) do
      {{:value, {token, _pre_terms, _pre_pos} = entry}, new_buffer} ->
        # Update last emitted entry for accurate pushback semantics
        stream = %{stream | buffer: new_buffer, last_emitted_entry: entry}
        stream = maybe_refill_buffer(stream)
        token = process_token(token, stream)

        if token == nil do
          # Skip nil tokens (e.g., filtered EOL)
          do_next(stream)
        else
          {:ok, token, stream}
        end

      {:empty, _} ->
        stream = refill_buffer(stream)

        # Check if refill_buffer set an error, but only return error if no tokens were buffered
        cond do
          stream.error != nil and Keyword.get(stream.opts, :error_mode, :tolerant) == :strict and :queue.is_empty(stream.buffer) ->
            {:error, stream.error, stream}

          stream.eof and :queue.is_empty(stream.buffer) ->
            {:eof, stream}

          true ->
            do_next(stream)
        end
    end
  end

  @doc """
  Peek at the next token without consuming it.

  Returns `{:ok, token, stream}` or `{:eof, stream}`.
  """
  @spec peek(t()) :: {:ok, token(), t()} | {:eof, t()}
  def peek(%__MODULE__{eof: true, push: [], buffer: buffer} = stream) do
    case :queue.is_empty(buffer) do
      true -> {:eof, stream}
      false -> do_peek(stream)
    end
  end

  def peek(%__MODULE__{eof: true, push: [_ | _]} = stream) do
    # EOF but still have pushed tokens
    do_peek(stream)
  end

  def peek(%__MODULE__{error: error, opts: opts} = stream) when error != nil do
    # Check if we have buffered or pushed tokens to peek at first
    if has_buffered_tokens?(stream) do
      do_peek(stream)  # Can peek at already buffered tokens
    else
      # Only return error when no more buffered tokens to peek at
      if Keyword.get(opts, :error_mode, :tolerant) == :strict do
        {:error, error, stream}  # Return error, not EOF
      else
        do_peek(stream)
      end
    end
  end

  def peek(%__MODULE__{} = stream) do
    do_peek(stream)
  end

  defp do_peek(%__MODULE__{push: [{token, _, _} | _]} = stream) do
    {:ok, token, stream}
  end

  defp do_peek(%__MODULE__{buffer: buffer} = stream) do
    case :queue.peek(buffer) do
      {:value, {token, _pre_terms, _pre_pos}} ->
        token = process_token(token, stream)

        if token == nil do
          # Skip nil tokens and peek the next one
          # We need to consume it temporarily
          {{:value, _}, new_buffer} = :queue.out(buffer)
          stream = %{stream | buffer: new_buffer}
          do_peek(stream)
        else
          {:ok, token, stream}
        end

      :empty ->
        stream = refill_buffer(stream)

        cond do
          stream.error != nil and Keyword.get(stream.opts, :error_mode, :tolerant) == :strict ->
            {:error, stream.error, stream}

          stream.eof and :queue.is_empty(stream.buffer) ->
            {:eof, stream}

          true ->
            # Only return EOF if we're at EOF and the buffer is still empty.
            # If the buffer received tokens, proceed to peek them even if EOF is set.
            do_peek(stream)
        end
    end
  end

  @doc """
  Peek at the next N tokens without consuming them.

  Returns `{:ok, tokens, stream}` or `{:eof, stream}`.
  """
  @spec peek_n(t(), pos_integer()) :: {:ok, [token()], t()} | {:eof, t()}
  def peek_n(stream, n) when n <= 0, do: {:ok, [], stream}

  def peek_n(%__MODULE__{eof: true, push: [], buffer: buffer} = stream, n) do
    case :queue.is_empty(buffer) do
      true -> {:eof, stream}
      false -> do_peek_n(stream, n)  # Still have buffered tokens
    end
  end

  def peek_n(%__MODULE__{eof: true, push: [_ | _]} = stream, n) do
    # EOF but still have pushed tokens
    do_peek_n(stream, n)
  end

  def peek_n(%__MODULE__{error: error, opts: opts} = stream, n) when error != nil do
    # Return buffered tokens even with error set
    if has_buffered_tokens?(stream) do
      do_peek_n(stream, n)  # Returns what's available
    else
      # When no tokens available and in strict mode, return empty list
      if Keyword.get(opts, :error_mode, :tolerant) == :strict do
        {:ok, [], stream}  # Empty list when no tokens available
      else
        do_peek_n(stream, n)
      end
    end
  end

  def peek_n(%__MODULE__{} = stream, n) do
    do_peek_n(stream, n)
  end

  defp do_peek_n(%__MODULE__{} = stream, n) do
    working_stream = ensure_buffer_size(stream, n)

    # Don't try to refill if there's an error in strict mode, but still return available tokens
    push_tokens =
      working_stream.push
      |> Enum.map(fn {t, _, _} -> t end)
      |> Enum.take(n)

    needed = n - length(push_tokens)

    tokens =
      if needed > 0 do
        buffer_tokens =
          working_stream.buffer
          |> :queue.to_list()
          |> Enum.map(fn {t, _, _} -> t end)
          |> Enum.take(needed)

        push_tokens ++ buffer_tokens
      else
        push_tokens
      end

    processed =
      tokens
      |> Enum.map(&process_token(&1, working_stream))
      |> Enum.reject(&is_nil/1)

    # Only preserve error state if one was discovered during buffer filling
    # peek_n should not modify the stream unless an error occurred
    result_stream =
      if working_stream.error != nil and stream.error == nil do
        %{stream | error: working_stream.error}
      else
        stream
      end

    case {processed, working_stream.eof} do
      {[], true} -> {:eof, result_stream}
      _ -> {:ok, processed, result_stream}
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
    Process.put({__MODULE__, :checkpoint, ref}, {stream.push, stream.buffer, stream.driver})
    {ref, stream}
  end

  @doc """
  Rewind to a previously created checkpoint identified by `ref`. Unless `delete_checkpoint?`
  flag is set to `false`, the function will free the process dictionary storage and invalidate the reference.
  """
  @spec rewind_to(t(), reference(), boolean()) :: t()
  def rewind_to(%__MODULE__{} = stream, ref, delete_checkpoint? \\ true) do
    case Process.get({__MODULE__, :checkpoint, ref}) do
      {push, buffer, driver} ->
        if delete_checkpoint? do
          Process.delete({__MODULE__, :checkpoint, ref})
        end

        %{stream | push: push, buffer: buffer, driver: driver}

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
          {:ok, token, new_stream} -> {[token], new_stream}
          {:eof, _} -> {:halt, stream}
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

  # Compute terms at the logical current position (before next token)
  defp terms_at_current_position(%__MODULE__{push: [{_tok, pre_terms, _} | _]} = stream) do
    cond do
      is_list(pre_terms) ->
        pre_terms

      match?({:value, {_, _, _}}, :queue.peek(stream.buffer)) ->
        case :queue.peek(stream.buffer) do
          {:value, {_, buf_terms, _}} when is_list(buf_terms) -> buf_terms
          _ -> Toxic.Driver.current_terminators(stream.driver)
        end

      true ->
        Toxic.Driver.current_terminators(stream.driver)
    end
  end

  defp terms_at_current_position(%__MODULE__{buffer: buffer} = stream) do
    case :queue.peek(buffer) do
      {:value, {_token, pre_terms, _}} when is_list(pre_terms) -> pre_terms
      _ -> Toxic.Driver.current_terminators(stream.driver)
    end
  end

  # Extract start position from a ranged meta token
  defp start_pos({_, {{sl, sc}, _end_meta, _extra}, _rest1, _rest2}), do: {sl, sc}
  defp start_pos({_, {{sl, sc}, _end_meta, _extra}, _rest}), do: {sl, sc}
  defp start_pos({_, {{sl, sc}, _end_meta, _extra}}), do: {sl, sc}

  # Private functions

  defp normalize_source_for_driver(source) when is_binary(source), do: String.to_charlist(source)
  defp normalize_source_for_driver(source) when is_list(source), do: source

  defp normalize_source_for_driver(source) when is_function(source, 2) do
    # For function sources, convert to charlist on each call
    fn line, column ->
      case source.(line, column) do
        {:more, binary} -> {:more, String.to_charlist(binary)}
        :eof -> :eof
      end
    end
  end

  # defp driver_opts(opts) do
  #   [
  #     unescape: Keyword.get(opts, :unescape, true),
  #     error_mode: Keyword.get(opts, :error_mode, :tolerant),
  #     error_sync: Keyword.get(opts, :error_sync, [:semicolon, :newline, :closer])
  #   ]
  # end

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
    case Toxic.Driver.next_with_validation(source_string, driver) do
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

  defp refill_buffer(%__MODULE__{eof: true} = stream), do: stream

  defp refill_buffer(%__MODULE__{opts: opts} = stream) do
    max_batch = Keyword.get(opts, :max_batch, 256)

    {tokens, source, new_driver, eof, error} = fetch_tokens_from_driver(stream, max_batch, opts)

    new_buffer =
      Enum.reduce(tokens, stream.buffer, fn entry, buf ->
        :queue.in(entry, buf)
      end)

    # Mark EOF if driver reported EOF or if fewer tokens than requested were returned without error.
    # This avoids an extra fetch cycle at EOF while preserving tolerant error recovery.
    stream_eof =
      cond do
        eof -> true
        error == nil and length(tokens) < max_batch -> true
        true -> stream.eof
      end

    %{
      stream
      | buffer: new_buffer,
        driver: new_driver,
        source: source,
        eof: stream_eof,
        error: error || stream.error
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
        stream = refill_buffer(stream)
        position(stream)
    end
  end

  defp maybe_refill_buffer(%__MODULE__{buffer: buffer, opts: opts} = stream) do
    min_size = div(Keyword.get(opts, :max_batch, 256), 4)

    if :queue.len(buffer) < min_size do
      refill_buffer(stream)
    else
      stream
    end
  end

  defp ensure_buffer_size(%__MODULE__{} = stream, needed) do
    buffer_size = :queue.len(stream.buffer) + length(stream.push)

    strict_error? =
      stream.error != nil and Keyword.get(stream.opts, :error_mode, :tolerant) == :strict

    if buffer_size < needed and not stream.eof and not strict_error? do
      stream
      |> refill_buffer()
      |> ensure_buffer_size(needed)
    else
      stream
    end
  end

  # TODO: remove
  defp process_token(token, %__MODULE__{opts: opts}) do
    token =
      if Keyword.get(opts, :eol_mode, :embed) == :embed do
        filter_eol_token(token)
      else
        token
      end

    # Apply space-sensitive rewrites if needed
    apply_rewrites(token)
  end

  # TODO: remove
  defp filter_eol_token({:eol, _meta}), do: nil
  defp filter_eol_token(token), do: token

  # TODO: remove
  defp apply_rewrites(nil), do: nil

  defp apply_rewrites(token) do
    # Space-sensitive rewrites would go here
    # For now, just return the token as-is
    token
  end

  defp extract_slice(source, start_offset, end_offset) when is_binary(source) do
    # TODO: this should use String.slice to handle unicode
    binary_part(source, start_offset, end_offset - start_offset)
  end

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

  defp has_buffered_tokens?(%__MODULE__{push: push, buffer: buffer}) do
    push != [] or not :queue.is_empty(buffer)
  end
end
