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
        ]

  @typedoc "Stream handle"
  @type t :: %__MODULE__{
          buffer: :queue.queue(token),
          push: [token],
          driver: Toxic.Driver.t(),
          opts: options,
          eof: boolean(),
          error: term() | nil
        }

  # TODO: Make sure it actually works with binary, iolist and producer function
  @typedoc "Source can be a binary or a producer function"
  @type source ::
          iodata() | ((non_neg_integer(), non_neg_integer()) -> {:more, binary()} | :eof)

  defstruct buffer: :queue.new(),
            push: [],
            driver: nil,
            source: nil,
            opts: [],
            eof: false,
            error: nil

  # Default options
  @default_opts [
    unescape: true,
    max_batch: 256,
    eol_mode: :emit,
    error_mode: :tolerant,
    error_sync: [:semicolon, :newline, :closer]
  ]

  @doc """
  Create a new token stream from source.

  ## Options
  - `:unescape` - Whether to unescape string contents (default: true)
  - `:max_batch` - Maximum tokens to fetch in one batch (default: 256)
  - `:eol_mode` - How to handle EOL tokens: `:embed` or `:emit` (default: :embed)
  - `:error_mode` - Error handling: `:tolerant` or `:strict` (default: :tolerant)
  - `:error_sync` - Sync points for error recovery (default: [:semicolon, :newline, :closer])
  """
  @spec new(iodata() | source(), pos_integer(), pos_integer(), options()) :: t()
  def new(source, line \\ 1, column \\ 1, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    %__MODULE__{
      driver: Toxic.Driver.new(),
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
      false -> do_next(stream)  # Still have tokens in buffer
    end
  end
  def next(%__MODULE__{eof: true, push: [_|_]} = stream) do
    # EOF but still have pushed tokens
    do_next(stream)
  end
  def next(%__MODULE__{error: error, opts: opts} = stream) when error != nil do
    if Keyword.get(opts, :error_mode, :tolerant) == :strict do
      {:eof, stream}
    else
      # In tolerant mode, continue despite errors
      do_next(stream)
    end
  end

  def next(%__MODULE__{} = stream) do
    do_next(stream)
  end

  defp do_next(%__MODULE__{push: [token | rest]} = stream) do
    {:ok, token, %{stream | push: rest}}
  end

  defp do_next(%__MODULE__{buffer: buffer} = stream) do
    case :queue.out(buffer) do
      {{:value, token}, new_buffer} ->
        stream = %{stream | buffer: new_buffer}
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
        if stream.eof do
          {:eof, stream}
        else
          do_next(stream)
        end
    end
  end

  @doc """
  Peek at the next token without consuming it.

  Returns `{:ok, token, stream}` or `{:eof, stream}`.
  """
  @spec peek(t()) :: {:ok, token(), t()} | {:eof, t()}
  def peek(%__MODULE__{eof: true} = stream), do: {:eof, stream}
  def peek(%__MODULE__{error: error, opts: opts} = stream) when error != nil do
    if Keyword.get(opts, :error_mode, :tolerant) == :strict do
      {:eof, stream}
    else
      do_peek(stream)
    end
  end

  def peek(%__MODULE__{} = stream) do
    do_peek(stream)
  end

  defp do_peek(%__MODULE__{push: [token | _]} = stream) do
    {:ok, token, stream}
  end

  defp do_peek(%__MODULE__{buffer: buffer} = stream) do
    case :queue.peek(buffer) do
      {:value, token} ->
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
        if stream.eof do
          {:eof, stream}
        else
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
  def peek_n(%__MODULE__{eof: true} = stream, _n), do: {:eof, stream}

  def peek_n(%__MODULE__{} = stream, n) do
    stream = ensure_buffer_size(stream, n)

    # TODO: make sure this works correctly: if unable to fill n, stream should not be marked as EOFed

    if stream.eof do
      {:eof, stream}
    else
      push_tokens = Enum.take(stream.push, n)
      needed = n - length(push_tokens)

      if needed > 0 do
        buffer_tokens = :queue.to_list(stream.buffer) |> Enum.take(needed)
        tokens = push_tokens ++ buffer_tokens

        if length(tokens) < n do
          {:eof, stream}
        else
          tokens = Enum.map(tokens, &process_token(&1, stream))
          {:ok, tokens, stream}
        end
      else
        {:ok, push_tokens, stream}
      end
    end
  end

  @doc """
  Push a token back onto the stream.
  """
  @spec pushback(t(), token()) :: t()
  def pushback(%__MODULE__{push: push} = stream, token) do
    %{stream | push: [token | push]}
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

  # @doc """
  # Get the current absolute position (start of next token).
  # """
  # @spec position(t()) :: {{pos_integer(), pos_integer()}, t()}
  # def position(%__MODULE__{driver: driver} = stream) do
  #   # Extract position from driver record using record macros
  #   line = toxic_driver(driver, :line)
  #   column = toxic_driver(driver, :column)
  #   {{line, column}, stream}
  # end

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
  @spec slice(t() | iodata(), non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer(), options()) :: t()
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
  def current_terminators(%__MODULE__{driver: driver} = stream) do
    terminators = :toxic_tokenizer.current_terminators(driver)
    {terminators, stream}
  end

  @doc """
  Peek at a potentially missing terminator.
  """
  @spec peek_missing_terminator(t()) :: {atom() | nil, t()}
  def peek_missing_terminator(%__MODULE__{driver: driver} = stream) do
    closer = :toxic_tokenizer.peek_missing_terminator(driver)
    {closer, stream}
  end

  # Private functions

  defp normalize_source_for_driver(source) when is_binary(source), do: String.to_charlist(source)
  defp normalize_source_for_driver(source) when is_list(source) do
    source |> IO.iodata_to_binary() |> String.to_charlist()
  end
  defp normalize_source_for_driver(source) when is_function(source, 2) do
    # For function sources, convert to charlist on each call
    fn line, column ->
      case source.(line, column) do
        {:more, binary} -> {:more, String.to_charlist(binary)}
        :eof -> :eof
      end
    end
  end

  defp driver_opts(opts) do
    [
      unescape: Keyword.get(opts, :unescape, true),
      error_mode: Keyword.get(opts, :error_mode, :tolerant),
      error_sync: Keyword.get(opts, :error_sync, [:semicolon, :newline, :closer])
    ]
  end

  defp fetch_tokens_from_driver(stream, max_batch, opts) do
    # Fetch a batch from the Erlang driver, then optionally collapse linear markers
    # TODO: slicing source
    source_string = normalize_source_for_driver(stream.source)
    {tokens, source_string, new_driver, eof} = fetch_tokens_from_driver(stream.driver, source_string, max_batch, [], 0, opts)

    {tokens, source_string,  new_driver, eof}
  end

  defp fetch_tokens_from_driver(driver, source_string, max_batch, acc, count, _opts) when count >= max_batch do
    {Enum.reverse(acc), source_string, driver, false}
  end

  defp fetch_tokens_from_driver(driver, source_string, max_batch, acc, count, opts) do

    case Toxic.Driver.next(source_string, driver) do
      {:ok, token, source_string, driver} ->
        processed_token = process_token(token, %__MODULE__{opts: opts})
        if processed_token == nil do
          # Skip nil tokens (e.g., filtered EOL) and continue
          fetch_tokens_from_driver(driver, source_string, max_batch, acc, count, opts)
        else
          fetch_tokens_from_driver(driver, source_string, max_batch, [processed_token | acc], count + 1, opts)
        end

      {:eof, driver} ->
        {Enum.reverse(acc), [], driver, true}

      {:error_token, meta, reason, driver} ->
        error_token = {:error_token, meta, reason}
        fetch_tokens_from_driver(driver, source_string, max_batch, [error_token | acc], count + 1, opts)
      
      {:error, _reason, _string, driver} ->
        # Error from driver - stop fetching tokens
        {Enum.reverse(acc), [], driver, false}
    end
  end

  defp refill_buffer(%__MODULE__{eof: true} = stream), do: stream
  defp refill_buffer(%__MODULE__{opts: opts} = stream) do
    max_batch = Keyword.get(opts, :max_batch, 256)

    {tokens, source, new_driver, eof} = fetch_tokens_from_driver(stream, max_batch, opts) |> dbg

    new_buffer = Enum.reduce(tokens, stream.buffer, fn token, buf ->
      :queue.in(token, buf)
    end)

    # Only set EOF if driver is at EOF AND we got no new tokens
    stream_eof = eof and tokens == []

    %{stream |
      buffer: new_buffer,
      driver: new_driver,
      source: source,
      eof: stream_eof
    }
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
    if buffer_size < needed and not stream.eof do
      stream
      |> refill_buffer()
      |> ensure_buffer_size(needed)
    else
      stream
    end
  end


  defp process_token(token, %__MODULE__{opts: opts}) do
    token = if Keyword.get(opts, :eol_mode, :embed) == :embed do
      filter_eol_token(token)
    else
      token
    end

    # Apply space-sensitive rewrites if needed
    apply_rewrites(token)
  end

  defp filter_eol_token({:eol, _meta}), do: nil
  defp filter_eol_token({:eol, _meta, _count}), do: nil
  defp filter_eol_token(token), do: token

  defp apply_rewrites(nil), do: nil
  defp apply_rewrites(token) do
    # Space-sensitive rewrites would go here
    # For now, just return the token as-is
    token
  end

  defp extract_slice(source, start_offset, end_offset) when is_binary(source) do
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
end
