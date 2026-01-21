defmodule Toxic.Driver do
  @moduledoc """
  Low-level single-token driver for Toxic tokenizer.

  The Driver is the core engine that emits one token at a time, managing:
  - **Contexts and scope**: Tracks interpolation state, terminators, and configuration
  - **Deferrals**: Buffers tokens that are emitted in a specific order (e.g., EOL markers)
  - **Error recovery**: Handles both strict mode (immediate halt) and tolerant mode
    (error-token emission with sync-point recovery)
  - **Position tracking**: Maintains accurate line/column positions including Unicode support

  ## Features

  - Single-token, streaming API for Pratt parsers and IDE integration
  - Linearized output (no nested containers, always flat token stream)
  - Ranged metadata: `{{start_line, start_col}, {end_line, end_col}, extra}`
  - Error-token emission with automatic sync-point recovery (tolerant mode)
  - Structural token synthesis for malformed input
  - Configurable error handling, recovery, and synthesization behavior

  ## Error Modes

  - `:strict` - Returns `{:error, reason, rest, state}` and halts tokenization
  - `:tolerant` - Emits `{:error_token, meta, %Toxic.Error{}}` inline and continues
    to the next sync point (semicolon, newline, closer, comma, or comment boundary)

  ## Configuration

  Error recovery is configured via fields on the `%Toxic.Driver{}` struct:
  - `error_mode`: `:strict` or `:tolerant`
  - `error_sync`: List of sync points to advance to during recovery
  - `error_max_skip`: Maximum bytes to skip before giving up on recovery
  - `insert_structural_closers`: Whether to synthesize missing/mismatched delimiters
  - `insert_identifier_sanitization`: Whether to sanitize invalid identifiers
  """

  import Toxic.Scope
  import Toxic.Token
  import Toxic.CharacterClassifier

  alias Toxic.Driver.Contexts
  alias Toxic.Driver.Recovery
  alias Toxic.Driver.Synthesis

  # Hot state record for high-performance tuple-based slow path.
  # Using Record.defrecordp gives us named field access while compiling to a tuple.
  require Record
  Record.defrecordp(:hot, [:line, :column, :scope, :contexts, :deferrals, :output, :recent_token])

  defstruct line: 1,
            column: 1,
            scope: nil,
            contexts: [:normal],
            error_mode: :tolerant,
            error_sync: [:semicolon, :newline, :closer, :comma, :comment, :whitespace],
            error_max_skip: 4096,
            insert_structural_closers: true,
            insert_identifier_sanitization: true,
            error_token_payload: :struct,
            lexer_backend: :charlist,
            deferrals: [],
            output: [],
            recent_token: nil

  @typedoc """
  Interpolation context kind.

  Identifies the type of string-like construct that can contain interpolation:
  - `:string` - Binary string ("...")
  - `:charlist` - Character list ('...')
  - `:atom_safe` - Atom with safe characters (:"...")
  - `:atom_unsafe` - Atom requiring quotes (:"...")
  - `:bin_heredoc` - Binary heredoc (\"\"\"...\"\"\"
  - `:list_heredoc` - List heredoc ('''...''')
  - `:sigil` - Sigil (~s"...", ~r/.../,  etc.)
  - `:quoted_identifier` - Quoted function name (Mod."name")
  """
  @type interp_kind ::
          :string
          | :charlist
          | :atom_safe
          | :atom_unsafe
          | :bin_heredoc
          | :list_heredoc
          | :sigil
          | :quoted_identifier

  @typedoc """
  Delimiter for interpolation context.

  Can be a single character (codepoint) or a character list for multi-char delimiters.
  Examples: `?"` (34), `?'` (39), `[?', ?', ?']` for triple quotes
  """
  @type interp_delim :: char() | charlist()

  @typedoc """
  Terminator stack.

  Either `:none` (for EEx compatibility, currently unused) or a list of terminator entries.
  Each entry is `{opening_delimiter, meta, indentation}`.
  """
  @type terminators :: :none | [{atom(), term(), non_neg_integer()}]

  @typedoc """
  Token as stored internally.

  Same shapes as `Toxic.token()` but before being returned to the user.
  """
  @type token :: {atom(), term(), term()}

  @typedoc """
  Interpolation context entry.

  Tuple containing:
  - `kind` - Type of interpolation context
  - `interpolation_allowed?` - Whether interpolation is supported
  - `delimiter` - Closing delimiter
  - `parent_terminators` - Terminator stack from enclosing scope
  - `start_info` - Map with `:line`, `:column`, `:token` for error reporting
  - `fragments` - Accumulated string fragments (in reverse order)
  - `saw_interpolation?` - Whether any `\#{...}` was encountered
  """
  @type interp_context ::
          {:interp, interp_kind(), boolean(), interp_delim(), terminators(),
           %{line: pos_integer(), column: pos_integer(), token: token()}, [binary()], boolean()}

  @typedoc "Parsing context stack: either `:normal` code or an interpolation context"
  @type context :: :normal | interp_context()

  @typedoc "Driver state"
  @type t :: %__MODULE__{
          line: pos_integer(),
          column: pos_integer(),
          contexts: [context()],
          error_mode: :tolerant | :strict,
          error_sync: [:semicolon | :newline | :closer | :comma | :comment | :whitespace],
          error_max_skip: non_neg_integer(),
          insert_structural_closers: boolean(),
          insert_identifier_sanitization: boolean(),
          error_token_payload: :struct | :tuple | :both,
          lexer_backend: :charlist | :binary,
          deferrals: [token()],
          output: [token()],
          recent_token: token() | nil,
          scope: Toxic.Scope.scope()
        }

  @type state_map :: %{
          line: pos_integer(),
          column: pos_integer(),
          contexts: [context()],
          error_mode: :tolerant | :strict,
          error_sync: [:semicolon | :newline | :closer | :comma | :comment | :whitespace],
          error_max_skip: non_neg_integer(),
          insert_structural_closers: boolean(),
          insert_identifier_sanitization: boolean(),
          error_token_payload: :struct | :tuple | :both,
          lexer_backend: :charlist | :binary,
          deferrals: [token()],
          output: [token()],
          recent_token: token() | nil,
          scope: Toxic.Scope.scope()
        }

  @type driver_state :: t() | state_map()

  @type cfg :: %{
          error_mode: :tolerant | :strict,
          error_sync: [:semicolon | :newline | :closer | :comma | :comment | :whitespace],
          error_max_skip: non_neg_integer(),
          insert_structural_closers: boolean(),
          insert_identifier_sanitization: boolean(),
          error_token_payload: :struct | :tuple | :both,
          lexer_backend: :charlist | :binary
        }

  @type driver_hot :: {Toxic.Scope.scope(), [context()], [token()], [token()], token() | nil}

  @type lookbehind :: {token() | nil, boolean(), non_neg_integer()}

  @spec new(keyword()) :: Toxic.Driver.t()
  def new(opts \\ []) do
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)
    cfg = build_cfg(opts)
    {scope, contexts, _deferrals, _output, _recent_token} = build_hot(opts)

    %__MODULE__{
      line: line,
      column: column,
      error_mode: cfg.error_mode,
      error_sync: cfg.error_sync,
      error_max_skip: cfg.error_max_skip,
      insert_structural_closers: cfg.insert_structural_closers,
      insert_identifier_sanitization: cfg.insert_identifier_sanitization,
      error_token_payload: cfg.error_token_payload,
      lexer_backend: cfg.lexer_backend,
      scope: scope,
      contexts: contexts
    }
  end

  @spec build_cfg(keyword()) :: cfg()
  def build_cfg(opts) do
    error_mode = Keyword.get(opts, :error_mode, :tolerant)

    %{
      error_mode: error_mode,
      error_sync:
        Keyword.get(opts, :error_sync, [
          :semicolon,
          :newline,
          :closer,
          :comma,
          :comment,
          :whitespace
        ]),
      error_max_skip: Keyword.get(opts, :error_max_skip, 4096),
      insert_structural_closers: Keyword.get(opts, :insert_structural_closers, true),
      insert_identifier_sanitization: Keyword.get(opts, :insert_identifier_sanitization, true),
      error_token_payload: Keyword.get(opts, :error_token_payload, :struct),
      lexer_backend: Keyword.get(opts, :lexer_backend, :charlist)
    }
  end

  @spec build_hot(keyword()) :: driver_hot()
  def build_hot(opts) do
    elixir_compatibility = Keyword.get(opts, :elixir_compatibility, false)
    preserve_comments = Keyword.get(opts, :preserve_comments, false)
    existing_atoms_only = Keyword.get(opts, :existing_atoms_only, false)
    static_atoms_encoder = Keyword.get(opts, :static_atoms_encoder, nil)
    column = Keyword.get(opts, :column, 1)

    scope =
      scope(
        elixir_compatibility: elixir_compatibility,
        preserve_comments: preserve_comments,
        existing_atoms_only: existing_atoms_only,
        static_atoms_encoder: static_atoms_encoder,
        column: column
      )

    {scope, [:normal], [], [], nil}
  end

  def cfg_from_driver(%__MODULE__{} = driver) do
    %{
      error_mode: driver.error_mode,
      error_sync: driver.error_sync,
      error_max_skip: driver.error_max_skip,
      insert_structural_closers: driver.insert_structural_closers,
      insert_identifier_sanitization: driver.insert_identifier_sanitization,
      error_token_payload: driver.error_token_payload,
      lexer_backend: driver.lexer_backend
    }
  end

  def hot_from_driver(%__MODULE__{} = driver) do
    {driver.scope, driver.contexts}
  end

  @typedoc "Input remaining to be tokenized (charlist or binary depending on backend)"
  @type input :: charlist() | binary()

  @typedoc "Error reason tuple in legacy format"
  @type error_reason :: {charlist(), charlist(), charlist()}

  @doc """
  Recover from a driver-level error in tolerant mode.

  Emits an error token and optionally structural insertions, then advances
  to the next sync point to continue tokenization.

  ## Parameters
  - `rest` - Remaining input
  - `state` - Driver state (must have `error_mode: :tolerant`)
  - `reason` - Error that occurred

  ## Returns
  Same shape as `next/2`:
  - `{:ok, token, rest, new_driver}` - Recovery successful, token emitted
  - `{:eof, new_driver}` - Reached end while recovering
  - `{:error, reason, rest, new_driver}` - Nested error during recovery

  """
  @spec recover(input(), t(), term()) ::
          {:ok, token(), input(), t()}
          | {:eof, t()}
          | {:error, error_reason(), input(), t()}
  def recover(rest, %__MODULE__{error_mode: :tolerant} = state, reason) do
    Recovery.emit_error_and_advance(reason, rest, state)
  end

  @spec step(input(), pos_integer(), pos_integer(), driver_hot(), cfg(), lookbehind()) ::
          {:ok, token(), input(), pos_integer(), pos_integer(), driver_hot()}
          | {:ok_many, [token()], input(), pos_integer(), pos_integer(), driver_hot()}
          | {:eof, driver_hot()}
          | {:error, error_reason(), input(), pos_integer(), pos_integer(), driver_hot()}
  def step(
        rest,
        line,
        column,
        {scope, contexts, deferrals, output, recent_token},
        cfg,
        lookbehind
      ) do
    # Optional tracing for re-lex analysis (enabled via Process.put(:toxic_trace_lexing, true))
    if Process.get(:toxic_trace_lexing, false) do
      rest_size = if is_binary(rest), do: byte_size(rest), else: length(rest)
      key = {__MODULE__, :step_calls}
      calls = Process.get(key, %{})
      Process.put(key, Map.update(calls, {line, column, rest_size}, 1, &(&1 + 1)))
    end

    case {deferrals, output} do
      {[], []} ->
        case step_fast(rest, line, column, scope, contexts, cfg, lookbehind) do
          {:ok, token, rest, line, column, scope, contexts} ->
            {:ok, token, rest, line, column, {scope, contexts, [], [], token}}

          :fallback ->
            step_slow(
              rest,
              line,
              column,
              {scope, contexts, [], [], recent_token},
              cfg,
              lookbehind
            )
        end

      # A2 optimization: Pop from output directly without calling step_slow/next_hot
      # This avoids the overhead of building hot record just to pop one token
      {[], [h | t]} ->
        {:ok, h, rest, line, column, {scope, contexts, [], t, h}}

      # Deferrals need processing - must go through slow path
      _ ->
        step_slow(
          rest,
          line,
          column,
          {scope, contexts, deferrals, output, recent_token},
          cfg,
          lookbehind
        )
    end
  end

  defp step_fast([], _line, _column, _scope, _contexts, _cfg, _lookbehind), do: :fallback
  defp step_fast(<<>>, _line, _column, _scope, _contexts, _cfg, _lookbehind), do: :fallback

  defp step_fast(rest, line, column, scope, [:normal | _] = contexts, cfg, lookbehind) do
    result =
      case cfg.lexer_backend do
        :binary ->
          Toxic.BinaryNormalTokenizer.next(rest, line, column, scope, lookbehind)

        _ ->
          Toxic.NormalTokenizer.next(rest, line, column, scope, lookbehind)
      end

    case result do
      {nil, rest, line, column, scope} ->
        step_fast(rest, line, column, scope, contexts, cfg, lookbehind)

      {{:token, token}, rest, line, column, scope} ->
        if fast_token?(token) do
          {:ok, token, rest, line, column, scope, contexts}
        else
          :fallback
        end

      _ ->
        :fallback
    end
  end

  defp step_fast(_rest, _line, _column, _scope, _contexts, _cfg, _lookbehind), do: :fallback

  defp step_slow(
         rest,
         line,
         column,
         {scope, contexts, deferrals, output, recent_token},
         cfg,
         _lookbehind
       ) do
    # Build hot record instead of map - avoids per-call allocation of large map
    state =
      hot(
        line: line,
        column: column,
        scope: scope,
        contexts: contexts,
        deferrals: deferrals,
        output: output,
        recent_token: recent_token
      )

    case next_hot(rest, state, cfg) do
      {:ok, token, new_rest, new_state} ->
        if hot(new_state, :deferrals) == [] and hot(new_state, :output) == [] do
          driver_hot = {
            hot(new_state, :scope),
            hot(new_state, :contexts),
            [],
            [],
            hot(new_state, :recent_token)
          }

          {:ok, token, new_rest, hot(new_state, :line), hot(new_state, :column), driver_hot}
        else
          collect_until_no_deferrals_hot(new_rest, new_state, cfg, [token])
        end

      {:eof, new_state} ->
        {:eof,
         {
           hot(new_state, :scope),
           hot(new_state, :contexts),
           hot(new_state, :deferrals),
           hot(new_state, :output),
           hot(new_state, :recent_token)
         }}

      {:error, reason, new_rest, new_state} ->
        driver_hot = {
          hot(new_state, :scope),
          hot(new_state, :contexts),
          hot(new_state, :deferrals),
          hot(new_state, :output),
          hot(new_state, :recent_token)
        }

        {:error, reason, new_rest, hot(new_state, :line), hot(new_state, :column), driver_hot}
    end
  end

  # Hot tuple version that avoids map allocations
  defp collect_until_no_deferrals_hot(rest, state, cfg, acc) do
    case next_hot(rest, state, cfg) do
      {:ok, token, new_rest, new_state} ->
        acc = [token | acc]

        if hot(new_state, :deferrals) == [] and hot(new_state, :output) == [] do
          tokens = :lists.reverse(acc)

          driver_hot = {
            hot(new_state, :scope),
            hot(new_state, :contexts),
            [],
            [],
            hot(new_state, :recent_token)
          }

          {:ok_many, tokens, new_rest, hot(new_state, :line), hot(new_state, :column), driver_hot}
        else
          collect_until_no_deferrals_hot(new_rest, new_state, cfg, acc)
        end

      {:eof, new_state} ->
        tokens = :lists.reverse(acc)

        driver_hot = {
          hot(new_state, :scope),
          hot(new_state, :contexts),
          hot(new_state, :deferrals),
          hot(new_state, :output),
          hot(new_state, :recent_token)
        }

        {:ok_many, tokens, rest, hot(new_state, :line), hot(new_state, :column), driver_hot}

      {:error, reason, new_rest, new_state} ->
        driver_hot = {
          hot(new_state, :scope),
          hot(new_state, :contexts),
          hot(new_state, :deferrals),
          hot(new_state, :output),
          hot(new_state, :recent_token)
        }

        {:error, reason, new_rest, hot(new_state, :line), hot(new_state, :column), driver_hot}
    end
  end

  defp fast_token?({kind, _meta, _}) when kind in [:identifier, :eol, :";", :","], do: false
  defp fast_token?({:quoted_identifier_end, _meta, _}), do: false
  defp fast_token?(_token), do: true

  @compile {:inline, fast_token?: 1}

  # ============================================================================
  # Hot tuple based tokenization (avoids map allocations in slow path)
  # ============================================================================

  # Pop from output queue first
  defp next_hot(rest, hot(output: [h | t]) = state, _cfg) do
    return_token_hot(h, rest, hot(state, output: t))
  end

  # EOF handling - charlist with empty deferrals
  defp next_hot([], hot(deferrals: [], contexts: contexts, scope: scope) = state, cfg) do
    case Contexts.pending_error(contexts, scope) do
      nil ->
        {:eof, state}

      error when cfg.error_mode == :strict ->
        line = hot(state, :line)
        column = hot(state, :column)

        case error do
          {:missing_interpolation, interp_context} ->
            reason = Contexts.missing_interpolation_reason(interp_context, line, column)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_context, interp_context} ->
            reason = Contexts.missing_terminator_reason(interp_context, line, column)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_scope, entry} ->
            reason = Contexts.missing_scope_terminator_reason(entry, line, column, scope)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}
        end

      error when cfg.error_mode == :tolerant ->
        emit_pending_error_hot(error, state, cfg)
    end
  end

  # EOF handling - charlist with non-empty deferrals
  defp next_hot([], hot(deferrals: [_ | _] = deferrals) = state, cfg) do
    next_hot([], hot(state, deferrals: [], output: :lists.reverse(deferrals)), cfg)
  end

  # EOF handling - binary backend with empty deferrals
  defp next_hot(
         <<>>,
         hot(deferrals: [], contexts: contexts, scope: scope) = state,
         %{lexer_backend: :binary} = cfg
       ) do
    case Contexts.pending_error(contexts, scope) do
      nil ->
        {:eof, state}

      error when cfg.error_mode == :strict ->
        line = hot(state, :line)
        column = hot(state, :column)

        case error do
          {:missing_interpolation, interp_context} ->
            reason = Contexts.missing_interpolation_reason(interp_context, line, column)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}

          {:missing_context, interp_context} ->
            reason = Contexts.missing_terminator_reason(interp_context, line, column)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}

          {:missing_scope, entry} ->
            reason = Contexts.missing_scope_terminator_reason(entry, line, column, scope)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}
        end

      error when cfg.error_mode == :tolerant ->
        emit_pending_error_hot(error, state, cfg)
    end
  end

  # EOF handling - binary backend with non-empty deferrals
  defp next_hot(
         <<>>,
         hot(deferrals: [_ | _] = deferrals) = state,
         %{lexer_backend: :binary} = cfg
       ) do
    next_hot(<<>>, hot(state, deferrals: [], output: :lists.reverse(deferrals)), cfg)
  end

  # Interpolation end `}` - charlist, mismatched delimiter
  defp next_hot(
         [?} | rest],
         hot(
           contexts: [
             :normal,
             {:interp, _kind, _interpolation, _delim, _parent_terminators, _start_info,
              _fragments, _saw_interp}
             | _contexts_rest
           ],
           scope: scope(terminators: [{start_token, _meta, _indent} = entry | _])
         ) = state,
         cfg
       )
       when start_token != :"{" do
    reason =
      Contexts.mismatched_delimiter_reason(entry, :"}", hot(state, :line), hot(state, :column))

    case cfg.error_mode do
      :strict ->
        reason_tuple = Toxic.Error.to_reason_tuple(reason)
        {:error, reason_tuple, rest, state}

      :tolerant ->
        emit_error_and_advance_hot_record(reason, rest, state, cfg)
    end
  end

  # Interpolation end `}` - charlist, normal case
  defp next_hot(
         [?} | rest],
         hot(
           line: line,
           column: column,
           contexts: [
             :normal,
             {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
              saw_interp}
             | contexts_rest
           ],
           deferrals: deferrals,
           scope: scope(terminators: [])
         ) = state,
         cfg
       ) do
    token_meta = {{line, column}, {line, column + 1}, nil}

    new_state =
      hot(state,
        column: column + 1,
        contexts: [
          {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
           saw_interp}
          | contexts_rest
        ],
        output: :lists.reverse([{:end_interpolation, token_meta, kind} | deferrals]),
        deferrals: []
      )

    next_hot(rest, new_state, cfg)
  end

  # Interpolation end `}` - binary backend, mismatched delimiter
  defp next_hot(
         <<?}, rest::binary>>,
         hot(
           contexts: [
             :normal,
             {:interp, _kind, _interpolation, _delim, _parent_terminators, _start_info,
              _fragments, _saw_interp}
             | _contexts_rest
           ],
           scope: scope(terminators: [{start_token, _meta, _indent} = entry | _])
         ) = state,
         %{lexer_backend: :binary} = cfg
       )
       when start_token != :"{" do
    reason =
      Contexts.mismatched_delimiter_reason(entry, :"}", hot(state, :line), hot(state, :column))

    case cfg.error_mode do
      :strict ->
        reason_tuple = Toxic.Error.to_reason_tuple(reason)
        {:error, reason_tuple, rest, state}

      :tolerant ->
        emit_error_and_advance_hot_record(reason, rest, state, cfg)
    end
  end

  # Interpolation end `}` - binary backend, normal case
  defp next_hot(
         <<?}, rest::binary>>,
         hot(
           line: line,
           column: column,
           contexts: [
             :normal,
             {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
              saw_interp}
             | contexts_rest
           ],
           deferrals: deferrals,
           scope: scope(terminators: [])
         ) = state,
         %{lexer_backend: :binary} = cfg
       ) do
    token_meta = {{line, column}, {line, column + 1}, nil}

    new_state =
      hot(state,
        column: column + 1,
        contexts: [
          {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
           saw_interp}
          | contexts_rest
        ],
        output: :lists.reverse([{:end_interpolation, token_meta, kind} | deferrals]),
        deferrals: []
      )

    next_hot(rest, new_state, cfg)
  end

  # Normal context tokenization - charlist
  defp next_hot(string, hot(contexts: [:normal | _]) = state, %{lexer_backend: :charlist} = cfg) do
    line = hot(state, :line)
    column = hot(state, :column)
    scope = hot(state, :scope)
    deferrals = hot(state, :deferrals)
    recent_token = hot(state, :recent_token)

    lookbehind = lookbehind_from_deferrals(deferrals, recent_token)

    result = Toxic.NormalTokenizer.next(string, line, column, scope, lookbehind)

    case handle_tokenize_result_hot(state, result, cfg) do
      {:error, reason, new_state} ->
        case cfg.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, new_state}

          :tolerant ->
            emit_error_and_advance_hot_record(reason, string, new_state, cfg)
        end

      {rest, new_state} ->
        next_hot(rest, new_state, cfg)
    end
  end

  # Normal context tokenization - binary
  defp next_hot(string, hot(contexts: [:normal | _]) = state, %{lexer_backend: :binary} = cfg) do
    line = hot(state, :line)
    column = hot(state, :column)
    scope = hot(state, :scope)
    deferrals = hot(state, :deferrals)
    recent_token = hot(state, :recent_token)

    lookbehind = lookbehind_from_deferrals(deferrals, recent_token)

    result = Toxic.BinaryNormalTokenizer.next(string, line, column, scope, lookbehind)

    case handle_tokenize_result_hot(state, result, cfg) do
      {:error, reason, new_state} ->
        case cfg.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, new_state}

          :tolerant ->
            emit_error_and_advance_hot_record(reason, string, new_state, cfg)
        end

      {rest, new_state} ->
        next_hot(rest, new_state, cfg)
    end
  end

  # Interpolation context - charlist backend
  defp next_hot(
         string,
         hot(
           line: line,
           column: column,
           scope: scope,
           contexts: [
             {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
              fragments, saw_interp}
             | contexts_rest
           ],
           recent_token: recent_token
         ) = state,
         %{lexer_backend: :charlist} = cfg
       ) do
    case Toxic.InterpolationTokenizer.next(
           line,
           column,
           scope,
           interpolation_allowed?,
           string,
           delim
         ) do
      {:error, reason} ->
        case cfg.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            emit_error_and_advance_hot_record(reason, string, state, cfg)
        end

      {:fragment, meta(start_line, start_column, _end_line, end_column, extra), binary_part, rest,
       new_line, new_column, new_scope} ->
        {binary_part, adjusted_line} =
          case recent_token do
            {token_kind, _, _} when token_kind in [:bin_heredoc_start, :list_heredoc_start] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, new_line - 1}

            {:sigil_start, _, {_, sigil_delim}} when sigil_delim in ["\"\"\"", "'''"] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, new_line - 1}

            _ ->
              {binary_part, new_line}
          end

        updated_contexts = [
          {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
           [binary_part | fragments], saw_interp}
          | contexts_rest
        ]

        return_token_hot(
          {:string_fragment, meta(start_line, start_column, adjusted_line, end_column, extra),
           binary_part},
          rest,
          hot(state,
            line: adjusted_line,
            column: new_column,
            scope: new_scope,
            contexts: updated_contexts
          )
        )

      {:done, done_meta, indent, rest, new_line, new_column, new_scope} when kind == :sigil ->
        end_token = token(:sigil_end, done_meta, delim, indent)
        {rest, modifiers} = Toxic.NormalTokenizer.Sigil.collect_modifiers(rest)
        modifiers_length = length(modifiers)

        output =
          if modifiers_length != 0 do
            [{:sigil_modifiers, meta(new_line, new_column, modifiers_length, nil), modifiers}]
          else
            []
          end

        return_token_hot(
          end_token,
          rest,
          hot(state,
            line: new_line,
            column: new_column + modifiers_length,
            scope: scope(new_scope, terminators: parent_terminators),
            contexts: contexts_rest,
            output: output
          )
        )

      {:done, done_meta, indent, rest, new_line, new_column, new_scope}
      when kind in [:bin_heredoc, :list_heredoc] ->
        end_token_type =
          case kind do
            :list_heredoc -> :list_heredoc_end
            :bin_heredoc -> :bin_heredoc_end
          end

        updated_scope =
          if end_token_type == :list_heredoc_end and delim == [?', ?', ?'] do
            warning =
              Toxic.Warning.deprecated_charlist(start_info.line, start_info.column, ~c"'''")

            Toxic.Scope.prepend_warning(warning, new_scope)
          else
            new_scope
          end

        return_token_hot(
          token(end_token_type, done_meta, delim, indent),
          rest,
          hot(state,
            line: new_line,
            column: new_column,
            scope: scope(updated_scope, terminators: parent_terminators),
            contexts: contexts_rest
          )
        )

      {:done, done_meta, nil, rest, new_line, new_column, new_scope}
      when kind == :quoted_identifier ->
        end_token_type =
          case rest do
            [?( | _] -> :quoted_paren_identifier_end
            [?[ | _] -> :quoted_bracket_identifier_end
            _ -> :quoted_identifier_end
          end

        updated_scope =
          case Contexts.is_unnecessary_quote(
                 :lists.reverse(fragments),
                 saw_interp,
                 :quoted_identifier,
                 new_scope
               ) do
            {true, content} ->
              Contexts.maybe_warn_unnecessary_quote(
                :quoted_identifier,
                content,
                delim,
                start_info.line,
                start_info.column,
                new_scope
              )

            false ->
              new_scope
          end

        if end_token_type == :quoted_identifier_end do
          next_hot(
            rest,
            hot(state,
              line: new_line,
              column: new_column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest,
              deferrals: [{end_token_type, done_meta, delim}]
            ),
            cfg
          )
        else
          return_token_hot(
            {end_token_type, done_meta, delim},
            rest,
            hot(state,
              line: new_line,
              column: new_column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest
            )
          )
        end

      {:done, done_meta, nil, rest, new_line, new_column, new_scope} ->
        handle_done_string_hot(
          state,
          cfg,
          kind,
          delim,
          parent_terminators,
          start_info,
          fragments,
          saw_interp,
          contexts_rest,
          done_meta,
          rest,
          new_line,
          new_column,
          new_scope
        )

      {:begin_interpolation, interp_meta, rest, new_line, new_column, new_scope} ->
        if kind == :quoted_identifier do
          reason =
            Contexts.interpolation_in_quoted_identifier_reason(
              start_info.line,
              start_info.column,
              delim
            )

          case cfg.error_mode do
            :strict ->
              reason_tuple = Toxic.Error.to_reason_tuple(reason)
              {:error, reason_tuple, rest, state}

            :tolerant ->
              emit_error_and_advance_hot_record(
                reason,
                rest,
                hot(state, line: new_line, column: new_column, scope: new_scope),
                cfg
              )
          end
        else
          updated_parent_context =
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, true}

          return_token_hot(
            {:begin_interpolation, interp_meta, kind},
            rest,
            hot(state,
              line: new_line,
              column: new_column,
              scope: new_scope,
              contexts: [:normal, updated_parent_context | contexts_rest]
            )
          )
        end
    end
  end

  # Interpolation context - binary backend
  defp next_hot(
         string,
         hot(
           line: line,
           column: column,
           scope: scope,
           contexts: [
             {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
              fragments, saw_interp}
             | contexts_rest
           ],
           recent_token: recent_token
         ) = state,
         %{lexer_backend: :binary} = cfg
       ) do
    case Toxic.BinaryInterpolationTokenizer.next(
           line,
           column,
           scope,
           interpolation_allowed?,
           string,
           delim
         ) do
      {:error, reason} ->
        case cfg.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            emit_error_and_advance_hot_record(reason, string, state, cfg)
        end

      {:fragment, meta(start_line, start_column, _end_line, end_column, extra), binary_part, rest,
       new_line, new_column, new_scope} ->
        {binary_part, adjusted_line} =
          case recent_token do
            {token_kind, _, _} when token_kind in [:bin_heredoc_start, :list_heredoc_start] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, new_line - 1}

            {:sigil_start, _, {_, sigil_delim}} when sigil_delim in ["\"\"\"", "'''"] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, new_line - 1}

            _ ->
              {binary_part, new_line}
          end

        updated_contexts = [
          {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
           [binary_part | fragments], saw_interp}
          | contexts_rest
        ]

        return_token_hot(
          {:string_fragment, meta(start_line, start_column, adjusted_line, end_column, extra),
           binary_part},
          rest,
          hot(state,
            line: adjusted_line,
            column: new_column,
            scope: new_scope,
            contexts: updated_contexts
          )
        )

      {:done, done_meta, indent, rest, new_line, new_column, new_scope} when kind == :sigil ->
        end_token = token(:sigil_end, done_meta, delim, indent)
        {rest, modifiers} = Toxic.BinaryNormalTokenizer.Sigil.collect_modifiers(rest)
        modifiers_length = length(modifiers)

        output =
          if modifiers_length != 0 do
            [{:sigil_modifiers, meta(new_line, new_column, modifiers_length, nil), modifiers}]
          else
            []
          end

        return_token_hot(
          end_token,
          rest,
          hot(state,
            line: new_line,
            column: new_column + modifiers_length,
            scope: scope(new_scope, terminators: parent_terminators),
            contexts: contexts_rest,
            output: output
          )
        )

      {:done, done_meta, indent, rest, new_line, new_column, new_scope}
      when kind in [:bin_heredoc, :list_heredoc] ->
        end_token_type =
          case kind do
            :list_heredoc -> :list_heredoc_end
            :bin_heredoc -> :bin_heredoc_end
          end

        updated_scope =
          if end_token_type == :list_heredoc_end and delim == [?', ?', ?'] do
            warning =
              Toxic.Warning.deprecated_charlist(start_info.line, start_info.column, ~c"'''")

            Toxic.Scope.prepend_warning(warning, new_scope)
          else
            new_scope
          end

        return_token_hot(
          token(end_token_type, done_meta, delim, indent),
          rest,
          hot(state,
            line: new_line,
            column: new_column,
            scope: scope(updated_scope, terminators: parent_terminators),
            contexts: contexts_rest
          )
        )

      {:done, done_meta, nil, rest, new_line, new_column, new_scope}
      when kind == :quoted_identifier ->
        end_token_type =
          case rest do
            <<?(, _::binary>> -> :quoted_paren_identifier_end
            <<?[, _::binary>> -> :quoted_bracket_identifier_end
            _ -> :quoted_identifier_end
          end

        updated_scope =
          case Contexts.is_unnecessary_quote(
                 :lists.reverse(fragments),
                 saw_interp,
                 :quoted_identifier,
                 new_scope
               ) do
            {true, content} ->
              Contexts.maybe_warn_unnecessary_quote(
                :quoted_identifier,
                content,
                delim,
                start_info.line,
                start_info.column,
                new_scope
              )

            false ->
              new_scope
          end

        if end_token_type == :quoted_identifier_end do
          next_hot(
            rest,
            hot(state,
              line: new_line,
              column: new_column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest,
              deferrals: [{end_token_type, done_meta, delim}]
            ),
            cfg
          )
        else
          return_token_hot(
            {end_token_type, done_meta, delim},
            rest,
            hot(state,
              line: new_line,
              column: new_column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest
            )
          )
        end

      {:done, done_meta, nil, rest, new_line, new_column, new_scope} ->
        handle_done_string_binary_hot(
          state,
          cfg,
          kind,
          delim,
          parent_terminators,
          start_info,
          fragments,
          saw_interp,
          contexts_rest,
          done_meta,
          rest,
          new_line,
          new_column,
          new_scope
        )

      {:begin_interpolation, interp_meta, rest, new_line, new_column, new_scope} ->
        if kind == :quoted_identifier do
          reason =
            Contexts.interpolation_in_quoted_identifier_reason(
              start_info.line,
              start_info.column,
              delim
            )

          case cfg.error_mode do
            :strict ->
              reason_tuple = Toxic.Error.to_reason_tuple(reason)
              {:error, reason_tuple, rest, state}

            :tolerant ->
              emit_error_and_advance_hot_record(
                reason,
                rest,
                hot(state, line: new_line, column: new_column, scope: new_scope),
                cfg
              )
          end
        else
          updated_parent_context =
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, true}

          return_token_hot(
            {:begin_interpolation, interp_meta, kind},
            rest,
            hot(state,
              line: new_line,
              column: new_column,
              scope: new_scope,
              contexts: [:normal, updated_parent_context | contexts_rest]
            )
          )
        end
    end
  end

  # Helper for handling :done result in string contexts (charlist)
  defp handle_done_string_hot(
         state,
         _cfg,
         kind,
         delim,
         parent_terminators,
         start_info,
         fragments,
         saw_interp,
         contexts_rest,
         done_meta,
         rest,
         new_line,
         new_column,
         new_scope
       ) do
    case rest do
      [?:, ws | tail] when is_space(ws) ->
        {{sl, sc}, {el, ec}, extra} = done_meta
        adj_meta = {{sl, sc}, {el, ec + 1}, extra}

        end_token_type =
          case new_scope do
            scope(existing_atoms_only: true) -> :kw_identifier_safe_end
            _ -> :kw_identifier_unsafe_end
          end

        updated_scope =
          case Contexts.is_unnecessary_quote(
                 :lists.reverse(fragments),
                 saw_interp,
                 end_token_type,
                 new_scope
               ) do
            {true, content} ->
              Contexts.maybe_warn_unnecessary_quote(
                end_token_type,
                content,
                delim,
                start_info.line,
                start_info.column,
                new_scope
              )

            false ->
              if delim == ?' do
                warning =
                  Toxic.Warning.deprecated_single_quote_keyword(
                    start_info.line,
                    start_info.column
                  )

                Toxic.Scope.prepend_warning(warning, new_scope)
              else
                new_scope
              end
          end

        {:ok, {end_token_type, adj_meta, delim}, [ws | tail],
         hot(state,
           line: new_line,
           column: new_column + 1,
           scope: scope(updated_scope, terminators: parent_terminators),
           contexts: contexts_rest,
           recent_token: {end_token_type, adj_meta, delim}
         )}

      _ ->
        end_token_type =
          case kind do
            :charlist -> :list_string_end
            :atom_safe -> :atom_safe_end
            :atom_unsafe -> :atom_unsafe_end
            _ -> :bin_string_end
          end

        updated_scope =
          if end_token_type in [:atom_safe_end, :atom_unsafe_end] do
            case Contexts.is_unnecessary_quote(
                   :lists.reverse(fragments),
                   saw_interp,
                   kind,
                   new_scope
                 ) do
              {true, content} ->
                {_, {{_start_line, token_start_col}, {_end_line, _end_col}, _extra}, _} =
                  start_info.token

                Contexts.maybe_warn_unnecessary_quote(
                  kind,
                  content,
                  delim,
                  start_info.line,
                  token_start_col,
                  new_scope
                )

              false ->
                new_scope
            end
          else
            if end_token_type == :list_string_end and delim == ?' do
              warning =
                Toxic.Warning.deprecated_charlist_detailed(start_info.line, start_info.column)

              Toxic.Scope.prepend_warning(warning, new_scope)
            else
              new_scope
            end
          end

        return_token_hot(
          {end_token_type, done_meta, delim},
          rest,
          hot(state,
            line: new_line,
            column: new_column,
            scope: scope(updated_scope, terminators: parent_terminators),
            contexts: contexts_rest
          )
        )
    end
  end

  # Helper for handling :done result in string contexts (binary)
  defp handle_done_string_binary_hot(
         state,
         _cfg,
         kind,
         delim,
         parent_terminators,
         start_info,
         fragments,
         saw_interp,
         contexts_rest,
         done_meta,
         rest,
         new_line,
         new_column,
         new_scope
       ) do
    case rest do
      <<?:, ws, tail::binary>> when is_space(ws) ->
        {{sl, sc}, {el, ec}, extra} = done_meta
        adj_meta = {{sl, sc}, {el, ec + 1}, extra}

        end_token_type =
          case new_scope do
            scope(existing_atoms_only: true) -> :kw_identifier_safe_end
            _ -> :kw_identifier_unsafe_end
          end

        updated_scope =
          case Contexts.is_unnecessary_quote(
                 :lists.reverse(fragments),
                 saw_interp,
                 end_token_type,
                 new_scope
               ) do
            {true, content} ->
              Contexts.maybe_warn_unnecessary_quote(
                end_token_type,
                content,
                delim,
                start_info.line,
                start_info.column,
                new_scope
              )

            false ->
              if delim == ?' do
                warning =
                  Toxic.Warning.deprecated_single_quote_keyword(
                    start_info.line,
                    start_info.column
                  )

                Toxic.Scope.prepend_warning(warning, new_scope)
              else
                new_scope
              end
          end

        {:ok, {end_token_type, adj_meta, delim}, <<ws, tail::binary>>,
         hot(state,
           line: new_line,
           column: new_column + 1,
           scope: scope(updated_scope, terminators: parent_terminators),
           contexts: contexts_rest,
           recent_token: {end_token_type, adj_meta, delim}
         )}

      _ ->
        end_token_type =
          case kind do
            :charlist -> :list_string_end
            :atom_safe -> :atom_safe_end
            :atom_unsafe -> :atom_unsafe_end
            _ -> :bin_string_end
          end

        updated_scope =
          if end_token_type in [:atom_safe_end, :atom_unsafe_end] do
            case Contexts.is_unnecessary_quote(
                   :lists.reverse(fragments),
                   saw_interp,
                   kind,
                   new_scope
                 ) do
              {true, content} ->
                {_, {{_start_line, token_start_col}, {_end_line, _end_col}, _extra}, _} =
                  start_info.token

                Contexts.maybe_warn_unnecessary_quote(
                  kind,
                  content,
                  delim,
                  start_info.line,
                  token_start_col,
                  new_scope
                )

              false ->
                new_scope
            end
          else
            if end_token_type == :list_string_end and delim == ?' do
              warning =
                Toxic.Warning.deprecated_charlist_detailed(start_info.line, start_info.column)

              Toxic.Scope.prepend_warning(warning, new_scope)
            else
              new_scope
            end
          end

        return_token_hot(
          {end_token_type, done_meta, delim},
          rest,
          hot(state,
            line: new_line,
            column: new_column,
            scope: scope(updated_scope, terminators: parent_terminators),
            contexts: contexts_rest
          )
        )
    end
  end

  # Return token helper for hot record
  defp return_token_hot(token, rest, state) do
    {:ok, token, rest, hot(state, recent_token: token)}
  end

  @compile {:inline, return_token_hot: 3}

  # ============================================================================
  # handle_tokenize_result_hot - hot record version of handle_tokenize_result
  # ============================================================================

  defp handle_tokenize_result_hot(state, result, _cfg) do
    deferrals = hot(state, :deferrals)
    output = hot(state, :output)
    contexts = hot(state, :contexts)

    case result do
      {:error, reason} ->
        {:error, reason, state}

      {nil, rest, line, column, scope} ->
        {rest, hot(state, line: line, column: column, scope: scope)}

      {events, rest, line, column, scope} when is_list(events) ->
        {rest, final_state} =
          Enum.reduce(events, {rest, state}, fn event, {r, s} ->
            handle_tokenize_result_hot(s, {event, r, line, column, scope}, nil)
          end)

        {rest, final_state}

      {:drop_not, rest, line, column, scope} ->
        {rest, hot(state, line: line, column: column, scope: scope, deferrals: tl(deferrals))}

      {:reset_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, _extra), extra_value} | t] =
          deferrals

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [{kind, meta(start_line, start_column, line, column, 0), extra_value} | t]
         )}

      {:increase_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, extra), extra_value} | t] =
          deferrals

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [
             {kind, meta(start_line, start_column, line, column, extra + 1), extra_value} | t
           ]
         )}

      {{:increase_eol_by, count}, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, extra), extra_value} | t] =
          deferrals

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [
             {kind, meta(start_line, start_column, line, column, extra + count), extra_value} | t
           ]
         )}

      {{:token, {eol, _meta, _extra} = token, _lookbehind}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: [token]
         )}

      {{:token, {eol, _meta, _extra} = token}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: [token]
         )}

      {:transform_into_do_identifier, rest, line, column, scope} ->
        {output_tokens, deferrals_result} =
          case deferrals do
            [{:identifier, def_meta, name}] ->
              {[{:do_identifier, def_meta, name}], []}

            [{:quoted_identifier_end, def_meta, name}] ->
              {[{:quoted_do_identifier_end, def_meta, name}], []}

            _ ->
              {[], deferrals}
          end

        new_output = append_deferrals(output, deferrals_result, output_tokens)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: []
         )}

      {{:token, {:identifier, _, _} = token, _lookbehind}, rest, line, column, scope} ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: [token]
         )}

      {{:token, {:identifier, _, _} = token}, rest, line, column, scope} ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: [token]
         )}

      {{:token, token, _lookbehind}, rest, line, column, scope} ->
        new_output = append_deferrals(output, deferrals, [token])

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [],
           output: new_output
         )}

      {{:token, token}, rest, line, column, scope} ->
        new_output = append_deferrals(output, deferrals, [token])

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [],
           output: new_output
         )}

      {{:dual_op_identifier, token}, rest, line, column, scope} ->
        {output_tokens, deferrals_result} =
          case deferrals do
            [{:identifier, def_meta, name}] ->
              {[{:op_identifier, def_meta, name}, token], []}

            [{:quoted_identifier_end, def_meta, name}] ->
              {[{:quoted_op_identifier_end, def_meta, name}, token], []}

            _ ->
              {[token], deferrals}
          end

        new_output = append_deferrals(output, deferrals_result, output_tokens)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: []
         )}

      {{:token_with_eol, {:unary_op, _meta, :not} = token, _lookbehind}, rest, line, column,
       scope} ->
        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [token | deferrals]
         )}

      {{:token_with_eol, {:unary_op, _meta, :not} = token}, rest, line, column, scope} ->
        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           deferrals: [token | deferrals]
         )}

      {{:token_with_eol, token, _lookbehind}, rest, line, column, scope} ->
        carry_with_recent =
          case {token, deferrals} do
            {left, [{:eol, _, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        new_output = flush_deferrals(output, carry_with_recent)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: []
         )}

      {{:token_with_eol, token}, rest, line, column, scope} ->
        carry_with_recent =
          case {token, deferrals} do
            {left, [{:eol, _, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        new_output = flush_deferrals(output, carry_with_recent)

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope,
           output: new_output,
           deferrals: []
         )}

      {{:switch_to_interp, start_token, interp_kind, interpolation_allowed?, delimiter}, rest,
       line, column, scope = scope(terminators: terminators)} ->
        start_info = Contexts.compute_start_info(start_token, delimiter, line, column)

        new_contexts = [
          {:interp, interp_kind, interpolation_allowed?, delimiter, terminators, start_info, [],
           false}
          | contexts
        ]

        new_output = append_deferrals(output, deferrals, [start_token])

        {rest,
         hot(state,
           line: line,
           column: column,
           scope: scope(scope, terminators: []),
           output: new_output,
           deferrals: [],
           contexts: new_contexts
         )}
    end
  end

  # ============================================================================
  # Error handling helpers for hot record
  # ============================================================================

  defp emit_error_and_advance_hot_record(reason, rest, state, cfg) do
    # Convert hot record to map for Recovery module
    state_map = %{
      line: hot(state, :line),
      column: hot(state, :column),
      scope: hot(state, :scope),
      contexts: hot(state, :contexts),
      error_mode: cfg.error_mode,
      error_sync: cfg.error_sync,
      error_max_skip: cfg.error_max_skip,
      insert_structural_closers: cfg.insert_structural_closers,
      insert_identifier_sanitization: cfg.insert_identifier_sanitization,
      error_token_payload: cfg.error_token_payload,
      lexer_backend: cfg.lexer_backend,
      deferrals: hot(state, :deferrals),
      output: hot(state, :output),
      recent_token: hot(state, :recent_token)
    }

    {:ok_many, [token | rest_tokens], new_rest, new_state} =
      Recovery.emit_error_and_advance_many(reason, rest, state_map)

    # Convert back to hot record
    result_state =
      hot(
        line: new_state.line,
        column: new_state.column,
        scope: new_state.scope,
        contexts: new_state.contexts,
        deferrals: new_state.deferrals,
        output: rest_tokens,
        recent_token: token
      )

    {:ok, token, new_rest, result_state}
  end

  defp emit_pending_error_hot(
         {:missing_interpolation,
          {:interp, kind, _allow, _delim, _parents, _start, _frags, _saw} = interp_context},
         state,
         cfg
       ) do
    line = hot(state, :line)
    column = hot(state, :column)
    output = hot(state, :output)
    contexts = hot(state, :contexts)

    reason = Contexts.missing_interpolation_reason(interp_context, line, column)
    meta0 = meta(line, column, line, column, nil)
    error_token = {:error_token, meta0, error_payload_hot(reason, cfg)}

    inserted =
      if cfg.insert_structural_closers, do: [{:end_interpolation, meta0, kind}], else: []

    new_contexts = Contexts.drop_first_normal_before_interp(contexts)
    new_output = output ++ [error_token | inserted]

    {:ok, hd(new_output), [],
     hot(state,
       contexts: new_contexts,
       output: tl(new_output),
       recent_token: hd(new_output)
     )}
  end

  defp emit_pending_error_hot(
         {:missing_context,
          {:interp, kind, _allow, delim, parent_terms, _start, _frags, _saw} = interp_context},
         state,
         cfg
       ) do
    line = hot(state, :line)
    column = hot(state, :column)
    scope = hot(state, :scope)
    output = hot(state, :output)
    contexts = hot(state, :contexts)

    reason = Contexts.missing_terminator_reason(interp_context, line, column)
    meta0 = meta(line, column, line, column, nil)
    error_token = {:error_token, meta0, error_payload_hot(reason, cfg)}

    inserted =
      if cfg.insert_structural_closers,
        do: [Synthesis.synthesize_end_for_kind(kind, delim, meta0)],
        else: []

    new_scope = scope(scope, terminators: parent_terms)
    new_contexts = Contexts.drop_first_interp(contexts)
    new_output = output ++ [error_token | inserted]

    {:ok, hd(new_output), [],
     hot(state,
       contexts: new_contexts,
       scope: new_scope,
       output: tl(new_output),
       recent_token: hd(new_output)
     )}
  end

  defp emit_pending_error_hot({:missing_scope, {start, _meta, _indent} = entry}, state, cfg) do
    line = hot(state, :line)
    column = hot(state, :column)
    scope = hot(state, :scope)
    output = hot(state, :output)

    reason = Contexts.missing_scope_terminator_reason(entry, line, column, scope)
    meta0 = meta(line, column, line, column, nil)
    error_token = {:error_token, meta0, error_payload_hot(reason, cfg)}

    scope(terminators: terms) = scope
    [_ | rest] = terms
    new_scope = scope(scope, terminators: rest)

    inserted =
      if cfg.insert_structural_closers, do: [{closing_for(start), meta0, nil}], else: []

    new_output = output ++ [error_token | inserted]

    {:ok, hd(new_output), [],
     hot(state,
       scope: new_scope,
       output: tl(new_output),
       recent_token: hd(new_output)
     )}
  end

  defp error_payload_hot(%Toxic.Error{} = error, cfg) do
    error = Toxic.Error.safe_validate(error)

    case cfg.error_token_payload do
      :struct -> error
      :tuple -> Toxic.Error.safe_to_reason_tuple(error)
      :both -> {error, Toxic.Error.safe_to_reason_tuple(error)}
    end
  end

  @doc """
  Get the next token from the driver.

  This is the low-level single-token driver interface. Most users should use
  `Toxic` instead, which provides buffering and lookahead.

  ## Parameters
  - `rest` - Remaining input as a charlist
  - `state` - Current driver state

  ## Returns
  - `{:ok, token, rest, new_state}` - Successfully produced a token
  - `{:eof, new_state}` - Reached end of input
  - `{:error, reason, rest, new_state}` - Error in strict mode

  """
  @spec next(input(), driver_state()) ::
          {:ok, token(), input(), driver_state()}
          | {:eof, driver_state()}
          | {:error, error_reason(), input(), driver_state()}
  def next(rest, %{output: [h | t]} = state) do
    return_token(h, rest, %{state | output: t})
  end

  def next([], %{deferrals: []} = state) do
    case Contexts.pending_error(state.contexts, state.scope) do
      nil ->
        {:eof, state}

      error when state.error_mode == :strict ->
        case error do
          {:missing_interpolation, interp_context} ->
            reason =
              Contexts.missing_interpolation_reason(interp_context, state.line, state.column)

            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_context, interp_context} ->
            reason = Contexts.missing_terminator_reason(interp_context, state.line, state.column)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_scope, entry} ->
            reason =
              Contexts.missing_scope_terminator_reason(
                entry,
                state.line,
                state.column,
                state.scope
              )

            {:error, Toxic.Error.to_reason_tuple(reason), [], state}
        end

      error when state.error_mode == :tolerant ->
        emit_pending_error(error, state)
    end
  end

  def next([], %{deferrals: [_h | _t] = deferrals} = state) do
    next([], %{state | deferrals: [], output: Enum.reverse(deferrals)})
  end

  # Binary backend EOF handling
  def next(<<>>, %{lexer_backend: :binary, deferrals: []} = state) do
    case Contexts.pending_error(state.contexts, state.scope) do
      nil ->
        {:eof, state}

      error when state.error_mode == :strict ->
        case error do
          {:missing_interpolation, interp_context} ->
            reason =
              Contexts.missing_interpolation_reason(interp_context, state.line, state.column)

            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}

          {:missing_context, interp_context} ->
            reason = Contexts.missing_terminator_reason(interp_context, state.line, state.column)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}

          {:missing_scope, entry} ->
            reason =
              Contexts.missing_scope_terminator_reason(
                entry,
                state.line,
                state.column,
                state.scope
              )

            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}
        end

      error when state.error_mode == :tolerant ->
        emit_pending_error(error, state)
    end
  end

  def next(<<>>, %{lexer_backend: :binary, deferrals: [_h | _t] = deferrals} = state) do
    next(<<>>, %{state | deferrals: [], output: Enum.reverse(deferrals)})
  end

  def next(
        [?} | rest],
        %{
          contexts: [
            :normal,
            {:interp, _kind, _interpolation, _delim, _parent_terminators, _start_info, _fragments,
             _saw_interp}
            | _contexts_rest
          ],
          scope: scope(terminators: [{start_token, _meta, _indent} = entry | _])
        } =
          state
      )
      when start_token != :"{" do
    reason = Contexts.mismatched_delimiter_reason(entry, :"}", state.line, state.column)

    case state.error_mode do
      :strict ->
        reason_tuple = Toxic.Error.to_reason_tuple(reason)
        {:error, reason_tuple, rest, state}

      :tolerant ->
        emit_error_and_advance_hot(reason, rest, state)
    end
  end

  def next(
        [?} | rest],
        %{
          contexts: [
            :normal,
            {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
             saw_interp}
            | contexts_rest
          ],
          deferrals: deferrals,
          scope: scope(terminators: [])
        } =
          state
      ) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, nil}

    new_state = %{
      state
      | column: state.column + 1,
        contexts: [
          {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
           saw_interp}
          | contexts_rest
        ],
        output: Enum.reverse([{:end_interpolation, meta, kind} | deferrals]),
        deferrals: []
    }

    next(rest, new_state)
  end

  # Binary backend interpolation end handling
  def next(
        <<?}, rest::binary>>,
        %{
          lexer_backend: :binary,
          contexts: [
            :normal,
            {:interp, _kind, _interpolation, _delim, _parent_terminators, _start_info, _fragments,
             _saw_interp}
            | _contexts_rest
          ],
          scope: scope(terminators: [{start_token, _meta, _indent} = entry | _])
        } =
          state
      )
      when start_token != :"{" do
    reason = Contexts.mismatched_delimiter_reason(entry, :"}", state.line, state.column)

    case state.error_mode do
      :strict ->
        reason_tuple = Toxic.Error.to_reason_tuple(reason)
        {:error, reason_tuple, rest, state}

      :tolerant ->
        emit_error_and_advance_hot(reason, rest, state)
    end
  end

  def next(
        <<?}, rest::binary>>,
        %{
          lexer_backend: :binary,
          contexts: [
            :normal,
            {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
             saw_interp}
            | contexts_rest
          ],
          deferrals: deferrals,
          scope: scope(terminators: [])
        } =
          state
      ) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, nil}

    new_state = %{
      state
      | column: state.column + 1,
        contexts: [
          {:interp, kind, interpolation, delim, parent_terminators, start_info, fragments,
           saw_interp}
          | contexts_rest
        ],
        output: Enum.reverse([{:end_interpolation, meta, kind} | deferrals]),
        deferrals: []
    }

    next(rest, new_state)
  end

  def next(string, %{contexts: [:normal | _], lexer_backend: :charlist} = state) do
    # Optional tracing for re-lex analysis (enabled via Process.put(:toxic_trace_lexing, true))
    if Process.get(:toxic_trace_lexing, false) do
      rest_size = length(string)
      key = {__MODULE__, :step_calls}
      calls = Process.get(key, %{})
      Process.put(key, Map.update(calls, {state.line, state.column, rest_size}, 1, &(&1 + 1)))
    end

    lookbehind = lookbehind_from_deferrals(state.deferrals, state.recent_token)

    result =
      Toxic.NormalTokenizer.next(
        string,
        state.line,
        state.column,
        state.scope,
        lookbehind
      )

    case handle_tokenize_result(state, result) do
      {:error, reason, state} ->
        case state.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            emit_error_and_advance_hot(reason, string, state)
        end

      {rest, state} ->
        next(rest, state)
    end
  end

  def next(string, %{contexts: [:normal | _], lexer_backend: :binary} = state) do
    # Optional tracing for re-lex analysis (enabled via Process.put(:toxic_trace_lexing, true))
    if Process.get(:toxic_trace_lexing, false) do
      rest_size = byte_size(string)
      key = {__MODULE__, :step_calls}
      calls = Process.get(key, %{})
      Process.put(key, Map.update(calls, {state.line, state.column, rest_size}, 1, &(&1 + 1)))
    end

    lookbehind = lookbehind_from_deferrals(state.deferrals, state.recent_token)

    result =
      Toxic.BinaryNormalTokenizer.next(
        string,
        state.line,
        state.column,
        state.scope,
        lookbehind
      )

    case handle_tokenize_result(state, result) do
      {:error, reason, state} ->
        case state.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            emit_error_and_advance_hot(reason, string, state)
        end

      {rest, state} ->
        next(rest, state)
    end
  end

  def next(
        string,
        %{
          lexer_backend: :charlist,
          contexts: [
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, saw_interp}
            | contexts_rest
          ]
        } =
          state
      ) do
    case Toxic.InterpolationTokenizer.next(
           state.line,
           state.column,
           state.scope,
           interpolation_allowed?,
           string,
           delim
         ) do
      {:error, reason} ->
        case state.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            emit_error_and_advance_hot(reason, string, state)
        end

      {:fragment, meta(start_line, start_column, _end_line, end_column, extra), binary_part, rest,
       line, column, scope} ->
        {binary_part, line} =
          case state.recent_token do
            {kind, _, _} when kind in [:bin_heredoc_start, :list_heredoc_start] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, line - 1}

            {:sigil_start, _, {_, delim}} when delim in ["\"\"\"", "'''"] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, line - 1}

            _ ->
              {binary_part, line}
          end

        # Update context to accumulate this fragment
        updated_contexts = [
          {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
           [binary_part | fragments], saw_interp}
          | contexts_rest
        ]

        return_token(
          {:string_fragment, meta(start_line, start_column, line, end_column, extra),
           binary_part},
          rest,
          %{
            state
            | line: line,
              column: column,
              scope: scope,
              contexts: updated_contexts
          }
        )

      {:done, meta, indent, rest, line, column, scope} when kind == :sigil ->
        end_token = token(:sigil_end, meta, delim, indent)

        {rest, modifiers} = Toxic.NormalTokenizer.Sigil.collect_modifiers(rest)
        modifiers_length = length(modifiers)

        output =
          if modifiers_length != 0 do
            [{:sigil_modifiers, meta(line, column, modifiers_length, nil), modifiers}]
          else
            []
          end

        return_token(end_token, rest, %{
          state
          | line: line,
            column: column + modifiers_length,
            scope: scope(scope, terminators: parent_terminators),
            contexts: contexts_rest,
            output: output
        })

      {:done, meta, indent, rest, line, column, scope}
      when kind in [:bin_heredoc, :list_heredoc] ->
        end_token_type =
          case kind do
            :list_heredoc -> :list_heredoc_end
            :bin_heredoc -> :bin_heredoc_end
          end

        # Emit charlist deprecation warning for list heredocs
        updated_scope =
          if end_token_type == :list_heredoc_end and delim == [?', ?', ?'] do
            warning =
              Toxic.Warning.deprecated_charlist(start_info.line, start_info.column, ~c"'''")

            Toxic.Scope.prepend_warning(warning, scope)
          else
            scope
          end

        return_token(token(end_token_type, meta, delim, indent), rest, %{
          state
          | line: line,
            column: column,
            scope: scope(updated_scope, terminators: parent_terminators),
            contexts: contexts_rest
        })

      {:done, meta, nil, rest, line, column, scope} when kind == :quoted_identifier ->
        end_token_type =
          case rest do
            [?( | _] -> :quoted_paren_identifier_end
            [?[ | _] -> :quoted_bracket_identifier_end
            _ -> :quoted_identifier_end
          end

        # Check for unnecessary quotes on calls
        updated_scope =
          case Contexts.is_unnecessary_quote(
                 Enum.reverse(fragments),
                 saw_interp,
                 :quoted_identifier,
                 scope
               ) do
            {true, content} ->
              Contexts.maybe_warn_unnecessary_quote(
                :quoted_identifier,
                content,
                delim,
                start_info.line,
                start_info.column,
                scope
              )

            false ->
              scope
          end

        if end_token_type == :quoted_identifier_end do
          next(rest, %{
            state
            | line: line,
              column: column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest,
              deferrals: [{end_token_type, meta, delim}]
          })
        else
          return_token({end_token_type, meta, delim}, rest, %{
            state
            | line: line,
              column: column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest
          })
        end

      {:done, meta, nil, rest, line, column, scope} ->
        case rest do
          [?:, ws | tail] when is_space(ws) ->
            {{sl, sc}, {el, ec}, extra} = meta
            adj_meta = {{sl, sc}, {el, ec + 1}, extra}

            end_token_type =
              case scope do
                scope(existing_atoms_only: true) ->
                  :kw_identifier_safe_end

                _ ->
                  :kw_identifier_unsafe_end
              end

            # Check for unnecessary quotes on keywords
            # For keywords: emit "unnecessary quote" OR "single quotes deprecated", not both
            # Note: Elixir reports warnings at column-1 (the ' position), so start_info.column
            # already points there (it's before the quote delimiter)
            updated_scope =
              case Contexts.is_unnecessary_quote(
                     Enum.reverse(fragments),
                     saw_interp,
                     end_token_type,
                     scope
                   ) do
                {true, content} ->
                  # Quotes are unnecessary - emit only this warning
                  Contexts.maybe_warn_unnecessary_quote(
                    end_token_type,
                    content,
                    delim,
                    start_info.line,
                    start_info.column,
                    scope
                  )

                false ->
                  # Quotes are necessary - check if single quotes deprecated
                  if delim == ?' do
                    warning =
                      Toxic.Warning.deprecated_single_quote_keyword(
                        start_info.line,
                        start_info.column
                      )

                    Toxic.Scope.prepend_warning(warning, scope)
                  else
                    scope
                  end
              end

            {:ok, {end_token_type, adj_meta, delim}, [ws | tail],
             %{
               state
               | line: line,
                 column: column + 1,
                 scope: scope(updated_scope, terminators: parent_terminators),
                 contexts: contexts_rest
             }}

          _ ->
            end_token_type =
              case kind do
                :charlist ->
                  :list_string_end

                :atom_safe ->
                  :atom_safe_end

                :atom_unsafe ->
                  :atom_unsafe_end

                _ ->
                  :bin_string_end
              end

            # Check for unnecessary quotes on atoms and emit charlist warning for charlists
            updated_scope =
              if end_token_type in [:atom_safe_end, :atom_unsafe_end] do
                case Contexts.is_unnecessary_quote(
                       Enum.reverse(fragments),
                       saw_interp,
                       kind,
                       scope
                     ) do
                  {true, content} ->
                    # For atoms, extract the token start column from the start_token meta
                    # The start_token has the : position, but start_info.column points to the delimiter
                    {_, {{_start_line, token_start_col}, {_end_line, _end_col}, _extra}, _} =
                      start_info.token

                    Contexts.maybe_warn_unnecessary_quote(
                      kind,
                      content,
                      delim,
                      start_info.line,
                      token_start_col,
                      scope
                    )

                  false ->
                    scope
                end
              else
                # For charlists, emit deprecation warning
                if end_token_type == :list_string_end and delim == ?' do
                  warning =
                    Toxic.Warning.deprecated_charlist_detailed(start_info.line, start_info.column)

                  Toxic.Scope.prepend_warning(warning, scope)
                else
                  scope
                end
              end

            return_token({end_token_type, meta, delim}, rest, %{
              state
              | line: line,
                column: column,
                scope: scope(updated_scope, terminators: parent_terminators),
                contexts: contexts_rest
            })
        end

      {:begin_interpolation, meta, rest, line, column, scope} ->
        if kind == :quoted_identifier do
          reason =
            Contexts.interpolation_in_quoted_identifier_reason(
              start_info.line,
              start_info.column,
              delim
            )

          case state.error_mode do
            :strict ->
              reason_tuple = Toxic.Error.to_reason_tuple(reason)
              {:error, reason_tuple, rest, state}

            :tolerant ->
              emit_error_and_advance_hot(reason, rest, %{
                state
                | line: line,
                  column: column,
                  scope: scope
              })
          end
        else
          # Mark that we saw interpolation in the parent context
          updated_parent_context =
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, true}

          updated = %{
            state
            | line: line,
              column: column,
              scope: scope,
              contexts: [:normal, updated_parent_context | contexts_rest]
          }

          return_token({:begin_interpolation, meta, kind}, rest, updated)
        end
    end
  end

  # Binary backend interpolation handler
  def next(
        string,
        %{
          lexer_backend: :binary,
          contexts: [
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, saw_interp}
            | contexts_rest
          ]
        } =
          state
      ) do
    case Toxic.BinaryInterpolationTokenizer.next(
           state.line,
           state.column,
           state.scope,
           interpolation_allowed?,
           string,
           delim
         ) do
      {:error, reason} ->
        case state.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            emit_error_and_advance_hot(reason, string, state)
        end

      {:fragment, meta(start_line, start_column, _end_line, end_column, extra), binary_part, rest,
       line, column, scope} ->
        {binary_part, line} =
          case state.recent_token do
            {kind, _, _} when kind in [:bin_heredoc_start, :list_heredoc_start] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, line - 1}

            {:sigil_start, _, {_, delim}} when delim in ["\"\"\"", "'''"] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, line - 1}

            _ ->
              {binary_part, line}
          end

        # Update context to accumulate this fragment
        updated_contexts = [
          {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
           [binary_part | fragments], saw_interp}
          | contexts_rest
        ]

        return_token(
          {:string_fragment, meta(start_line, start_column, line, end_column, extra),
           binary_part},
          rest,
          %{
            state
            | line: line,
              column: column,
              scope: scope,
              contexts: updated_contexts
          }
        )

      {:done, meta, indent, rest, line, column, scope} when kind == :sigil ->
        end_token = token(:sigil_end, meta, delim, indent)

        {rest, modifiers} = Toxic.BinaryNormalTokenizer.Sigil.collect_modifiers(rest)
        modifiers_length = length(modifiers)

        output =
          if modifiers_length != 0 do
            [{:sigil_modifiers, meta(line, column, modifiers_length, nil), modifiers}]
          else
            []
          end

        return_token(end_token, rest, %{
          state
          | line: line,
            column: column + modifiers_length,
            scope: scope(scope, terminators: parent_terminators),
            contexts: contexts_rest,
            output: output
        })

      {:done, meta, indent, rest, line, column, scope}
      when kind in [:bin_heredoc, :list_heredoc] ->
        end_token_type =
          case kind do
            :list_heredoc -> :list_heredoc_end
            :bin_heredoc -> :bin_heredoc_end
          end

        # Emit charlist deprecation warning for list heredocs
        updated_scope =
          if end_token_type == :list_heredoc_end and delim == [?', ?', ?'] do
            warning =
              Toxic.Warning.deprecated_charlist(start_info.line, start_info.column, ~c"'''")

            Toxic.Scope.prepend_warning(warning, scope)
          else
            scope
          end

        return_token(token(end_token_type, meta, delim, indent), rest, %{
          state
          | line: line,
            column: column,
            scope: scope(updated_scope, terminators: parent_terminators),
            contexts: contexts_rest
        })

      {:done, meta, nil, rest, line, column, scope} when kind == :quoted_identifier ->
        end_token_type =
          case rest do
            <<?(, _::binary>> -> :quoted_paren_identifier_end
            <<?[, _::binary>> -> :quoted_bracket_identifier_end
            _ -> :quoted_identifier_end
          end

        # Check for unnecessary quotes on calls
        updated_scope =
          case Contexts.is_unnecessary_quote(
                 Enum.reverse(fragments),
                 saw_interp,
                 :quoted_identifier,
                 scope
               ) do
            {true, content} ->
              Contexts.maybe_warn_unnecessary_quote(
                :quoted_identifier,
                content,
                delim,
                start_info.line,
                start_info.column,
                scope
              )

            false ->
              scope
          end

        if end_token_type == :quoted_identifier_end do
          next(rest, %{
            state
            | line: line,
              column: column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest,
              deferrals: [{end_token_type, meta, delim}]
          })
        else
          return_token({end_token_type, meta, delim}, rest, %{
            state
            | line: line,
              column: column,
              scope: scope(updated_scope, terminators: parent_terminators),
              contexts: contexts_rest
          })
        end

      {:done, meta, nil, rest, line, column, scope} ->
        case rest do
          <<?:, ws, tail::binary>> when is_space(ws) ->
            {{sl, sc}, {el, ec}, extra} = meta
            adj_meta = {{sl, sc}, {el, ec + 1}, extra}

            end_token_type =
              case scope do
                scope(existing_atoms_only: true) ->
                  :kw_identifier_safe_end

                _ ->
                  :kw_identifier_unsafe_end
              end

            # Check for unnecessary quotes on keywords
            # For keywords: emit "unnecessary quote" OR "single quotes deprecated", not both
            # Note: Elixir reports warnings at column-1 (the ' position), so start_info.column
            # already points there (it's before the quote delimiter)
            updated_scope =
              case Contexts.is_unnecessary_quote(
                     Enum.reverse(fragments),
                     saw_interp,
                     end_token_type,
                     scope
                   ) do
                {true, content} ->
                  # Quotes are unnecessary - emit only this warning
                  Contexts.maybe_warn_unnecessary_quote(
                    end_token_type,
                    content,
                    delim,
                    start_info.line,
                    start_info.column,
                    scope
                  )

                false ->
                  # Quotes are necessary - check if single quotes deprecated
                  if delim == ?' do
                    warning =
                      Toxic.Warning.deprecated_single_quote_keyword(
                        start_info.line,
                        start_info.column
                      )

                    Toxic.Scope.prepend_warning(warning, scope)
                  else
                    scope
                  end
              end

            {:ok, {end_token_type, adj_meta, delim}, <<ws, tail::binary>>,
             %{
               state
               | line: line,
                 column: column + 1,
                 scope: scope(updated_scope, terminators: parent_terminators),
                 contexts: contexts_rest
             }}

          _ ->
            end_token_type =
              case kind do
                :charlist ->
                  :list_string_end

                :atom_safe ->
                  :atom_safe_end

                :atom_unsafe ->
                  :atom_unsafe_end

                _ ->
                  :bin_string_end
              end

            # Check for unnecessary quotes on atoms and emit charlist warning for charlists
            updated_scope =
              if end_token_type in [:atom_safe_end, :atom_unsafe_end] do
                case Contexts.is_unnecessary_quote(
                       Enum.reverse(fragments),
                       saw_interp,
                       kind,
                       scope
                     ) do
                  {true, content} ->
                    # For atoms, extract the token start column from the start_token meta
                    # The start_token has the : position, but start_info.column points to the delimiter
                    {_, {{_start_line, token_start_col}, {_end_line, _end_col}, _extra}, _} =
                      start_info.token

                    Contexts.maybe_warn_unnecessary_quote(
                      kind,
                      content,
                      delim,
                      start_info.line,
                      token_start_col,
                      scope
                    )

                  false ->
                    scope
                end
              else
                # For charlists, emit deprecation warning
                if end_token_type == :list_string_end and delim == ?' do
                  warning =
                    Toxic.Warning.deprecated_charlist_detailed(start_info.line, start_info.column)

                  Toxic.Scope.prepend_warning(warning, scope)
                else
                  scope
                end
              end

            return_token({end_token_type, meta, delim}, rest, %{
              state
              | line: line,
                column: column,
                scope: scope(updated_scope, terminators: parent_terminators),
                contexts: contexts_rest
            })
        end

      {:begin_interpolation, meta, rest, line, column, scope} ->
        if kind == :quoted_identifier do
          reason =
            Contexts.interpolation_in_quoted_identifier_reason(
              start_info.line,
              start_info.column,
              delim
            )

          case state.error_mode do
            :strict ->
              reason_tuple = Toxic.Error.to_reason_tuple(reason)
              {:error, reason_tuple, rest, state}

            :tolerant ->
              emit_error_and_advance_hot(reason, rest, %{
                state
                | line: line,
                  column: column,
                  scope: scope
              })
          end
        else
          # Mark that we saw interpolation in the parent context
          updated_parent_context =
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, true}

          updated = %{
            state
            | line: line,
              column: column,
              scope: scope,
              contexts: [:normal, updated_parent_context | contexts_rest]
          }

          return_token({:begin_interpolation, meta, kind}, rest, updated)
        end
    end
  end

  defp handle_tokenize_result(
         state = %{contexts: contexts, deferrals: deferrals, output: output},
         result
       ) do
    case result do
      # :eof ->
      #   {[], %{state | output: Enum.reverse(deferrals), deferrals: []}}

      # Handle error case from tokenizer
      {:error, reason} ->
        {:error, reason, state}

      {nil, rest, line, column, scope} ->
        {rest, %{state | line: line, column: column, scope: scope}}

      {events, rest, line, column, scope} when is_list(events) ->
        {rest, state} =
          Enum.reduce(events, {rest, state}, fn event, {rest, state} ->
            handle_tokenize_result(state, {event, rest, line, column, scope})
          end)

        {rest, state}

      {:drop_not, rest, line, column, scope} ->
        {rest, %{state | line: line, column: column, scope: scope, deferrals: tl(deferrals)}}

      {:reset_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, _extra), extra} | t] =
          deferrals

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [{kind, meta(start_line, start_column, line, column, 0), extra} | t]
         }}

      {:increase_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, extra), extra_value} | t] =
          deferrals

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [
               {kind, meta(start_line, start_column, line, column, extra + 1), extra_value} | t
             ]
         }}

      # Multi-newline optimization: increase by specific count
      {{:increase_eol_by, count}, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, extra), extra_value} | t] =
          deferrals

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [
               {kind, meta(start_line, start_column, line, column, extra + count), extra_value}
               | t
             ]
         }}

      {{:token, {eol, _meta, _extra} = token, _lookbehind}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: [token]
         }}

      {{:token, {eol, _meta, _extra} = token}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: [token]
         }}

      {:transform_into_do_identifier, rest, line, column, scope} ->
        {output_tokens, deferrals_result} =
          case deferrals do
            [{:identifier, meta, name}] ->
              updated_token = {:do_identifier, meta, name}
              {[updated_token], []}

            [{:quoted_identifier_end, meta, name}] ->
              updated_token = {:quoted_do_identifier_end, meta, name}
              {[updated_token], []}

            # Defensive: if deferrals is empty or contains unexpected tokens,
            # emit any deferred tokens as-is without transformation
            _ ->
              {[], deferrals}
          end

        new_output = append_deferrals(output, deferrals_result, output_tokens)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: []
         }}

      {{:token, {:identifier, _, _} = token, _lookbehind}, rest, line, column, scope} ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: [token]
         }}

      {{:token, {:identifier, _, _} = token}, rest, line, column, scope} ->
        new_output = flush_deferrals(output, deferrals)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: [token]
         }}

      {{:token, token, _lookbehind}, rest, line, column, scope} ->
        new_output = append_deferrals(output, deferrals, [token])

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [],
             output: new_output
         }}

      {{:token, token}, rest, line, column, scope} ->
        new_output = append_deferrals(output, deferrals, [token])

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [],
             output: new_output
         }}

      {{:dual_op_identifier, token}, rest, line, column, scope} ->
        {output_tokens, deferrals_result} =
          case deferrals do
            [{:identifier, meta, name}] ->
              updated_token = {:op_identifier, meta, name}
              {[updated_token, token], []}

            [{:quoted_identifier_end, meta, name}] ->
              updated_token = {:quoted_op_identifier_end, meta, name}
              {[updated_token, token], []}

            # Defensive: if deferrals is empty or contains unexpected tokens,
            # emit both the dual_op and token as-is without transformation
            _ ->
              {[token], deferrals}
          end

        new_output = append_deferrals(output, deferrals_result, output_tokens)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: []
         }}

      {{:token_with_eol, {:unary_op, _meta, :not} = token, _lookbehind}, rest, line, column,
       scope} ->
        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [token | deferrals]
         }}

      {{:token_with_eol, {:unary_op, _meta, :not} = token}, rest, line, column, scope} ->
        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [token | deferrals]
         }}

      {{:token_with_eol, token, _lookbehind}, rest, line, column, scope} ->
        carry_with_recent =
          case {token, deferrals} do
            {left, [{:eol, _, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        new_output = flush_deferrals(output, carry_with_recent)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: []
         }}

      {{:token_with_eol, token}, rest, line, column, scope} ->
        carry_with_recent =
          case {token, deferrals} do
            {left, [{:eol, _, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        new_output = flush_deferrals(output, carry_with_recent)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: []
         }}

      {{:switch_to_interp, start_token, interp_kind, interpolation_allowed?, delimiter}, rest,
       line, column, scope = scope(terminators: terminators)} ->
        start_info = Contexts.compute_start_info(start_token, delimiter, line, column)

        contexts =
          [
            {:interp, interp_kind, interpolation_allowed?, delimiter, terminators, start_info, [],
             false}
            | contexts
          ]

        new_output = append_deferrals(output, deferrals, [start_token])

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope(scope, terminators: []),
             output: new_output,
             deferrals: [],
             contexts: contexts
         }}
    end
  end

  # Tolerant-mode recovery logic is implemented in Toxic.Driver.Recovery.

  @doc """
  Get the current terminator stack.

  Returns the stack of open delimiters, blocks, and string contexts that are
  currently awaiting their closing delimiter. This includes:
  - Structural delimiters from scope (parens, brackets, braces, do/end blocks)
  - Parent terminators from enclosing interpolation contexts
  - Delimiters from active string/heredoc/atom/sigil constructs

  Useful for:
  - Editor auto-completion
  - Syntax error recovery
  - Understanding current parser state

  ## Returns
  List of `{opening_delimiter, meta, indentation}` tuples in stack order
  (innermost first).

  ## Examples

      driver = Toxic.Driver.new()
      {:ok, _token, rest, driver} = Toxic.Driver.next(~c"(", driver)
      terms = Toxic.Driver.current_terminators(driver)
      # terms will include {:"(", meta, indent}

  """
  @spec current_terminators(t()) :: [{atom(), term(), non_neg_integer()}]
  def current_terminators(%__MODULE__{} = driver) do
    current_terminators_from(driver.scope, driver.contexts)
  end

  @spec current_terminators_from(Toxic.Scope.scope(), [context()]) ::
          [{atom(), term(), non_neg_integer()}]
  def current_terminators_from(scope, contexts) do
    # Collect current scope terminators and any parent terminators saved in
    # interpolation contexts on the driver's context stack, plus delimiters
    # from string/heredoc/atom/sigil constructs.

    # Read current terminators from scope record
    scope(terminators: current_terms) = scope

    current_terms =
      case current_terms do
        :none ->
          # TODO: not needed eex support?
          []

        other ->
          other
      end

    # Walk contexts to gather all parent terminators from interpolation frames
    # and add delimiter terminators from string-like constructs
    context_length = length(contexts)

    context_terms =
      contexts
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {:normal, index} when index < context_length - 1 ->
          # This is a :normal context inside an interpolation (not the root :normal)
          # Add the interpolation brace terminator
          [{:"{", nil, 0}]

        {{:interp, _kind, _allowed?, delim, parent_terms, _start_info, _fragments, _saw_interp},
         _index} ->
          # Get parent terminators
          parent_terms =
            case parent_terms do
              :none ->
                # TODO: not needed eex support?
                []

              list when is_list(list) ->
                list
            end

          # Add delimiter terminator
          delimiter_terminator = [{delimiter_atom(delim), nil, 0}]

          parent_terms ++ delimiter_terminator

        {:normal, _index} ->
          # Root :normal context does not have interpolation brace terminator
          []
      end)

    current_terms ++ context_terms
  end

  defp delimiter_atom([single]) when is_integer(single), do: delimiter_atom(single)
  defp delimiter_atom([?", ?", ?"]), do: :"\"\"\""
  defp delimiter_atom([?', ?', ?']), do: :"'''"
  defp delimiter_atom(?"), do: :"\""
  defp delimiter_atom(?'), do: :"'"
  defp delimiter_atom(?/), do: :/
  defp delimiter_atom(?|), do: :|
  defp delimiter_atom(?)), do: :")"
  defp delimiter_atom(?]), do: :"]"
  defp delimiter_atom(?}), do: :"}"
  defp delimiter_atom(?>), do: :>
  defp delimiter_atom(_), do: :unknown_delimiter

  @doc """
  Get the expected closing delimiter for an opening delimiter.

  Maps opening delimiters to their corresponding closers. For symmetric
  delimiters (like string quotes), returns the same delimiter.

  ## Parameters
  - `opening` - The opening delimiter atom

  ## Returns
  The corresponding closing delimiter atom.

  ## Examples

      iex> Toxic.Driver.closing_for(:"(")
      :")"

      iex> Toxic.Driver.closing_for(:do)
      :end

      iex> Toxic.Driver.closing_for(:"\"")
      :"\""

  """
  @spec closing_for(atom()) :: atom()
  def closing_for(:fn), do: :end
  def closing_for(:do), do: :end
  def closing_for(:"("), do: :")"
  def closing_for(:"["), do: :"]"
  def closing_for(:"{"), do: :"}"
  def closing_for(:"<<"), do: :">>"

  # Handle string-like delimiters - the delimiter is already converted to atom in current_terminators
  def closing_for(delimiter) when is_atom(delimiter) do
    delimiter
  end

  defp return_token(token, rest, state) do
    {:ok, token, rest, %{state | recent_token: token}}
  end

  @compile {:inline, return_token: 3}

  defp lookbehind_from_deferrals([token | _], _recent_token), do: lookbehind_from_token(token)
  defp lookbehind_from_deferrals([], recent_token), do: lookbehind_from_token(recent_token)

  @compile {:inline, lookbehind_from_deferrals: 2}

  defp lookbehind_from_token(nil), do: {nil, false, 0}

  defp lookbehind_from_token({kind, {_, _, count}, _} = token)
       when kind in [:eol, :";", :","] and is_integer(count) and count > 0 do
    {token, true, count}
  end

  defp lookbehind_from_token(token), do: {token, false, 0}

  @compile {:inline, lookbehind_from_token: 1}

  # Inlined from Toxic.Driver.Deferrals for cross-module call elimination
  # When output is empty, just reverse deferrals - no concatenation needed
  defp flush_deferrals([], deferrals), do: :lists.reverse(deferrals)
  # When deferrals is empty, just return output - no reverse needed
  defp flush_deferrals(output, []), do: output
  # General case: concatenate output with reversed deferrals
  defp flush_deferrals(output, deferrals), do: output ++ :lists.reverse(deferrals)

  # When output is empty, reverse deferrals onto tokens directly
  defp append_deferrals([], deferrals, tokens), do: :lists.reverse(deferrals, tokens)
  # When deferrals is empty, just concatenate output with tokens
  defp append_deferrals(output, [], tokens), do: output ++ tokens
  # General case: concatenate output with reversed deferrals and tokens
  defp append_deferrals(output, deferrals, tokens),
    do: output ++ :lists.reverse(deferrals, tokens)

  @compile {:inline, flush_deferrals: 2, append_deferrals: 3}

  defp emit_error_and_advance_hot(reason, rest, state) do
    {:ok_many, [token | rest_tokens], new_rest, new_state} =
      Recovery.emit_error_and_advance_many(reason, rest, state)

    {:ok, token, new_rest, %{new_state | output: rest_tokens, recent_token: token}}
  end

  defp emit_pending_error(
         {:missing_interpolation,
          {:interp, kind, _allow, _delim, _parents, _start, _frags, _saw} = interp_context},
         state
       ) do
    reason =
      Contexts.missing_interpolation_reason(interp_context, state.line, state.column)

    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    error_token = {:error_token, meta0, error_payload(reason, state)}

    inserted =
      if state.insert_structural_closers, do: [{:end_interpolation, meta0, kind}], else: []

    new_contexts = Contexts.drop_first_normal_before_interp(state.contexts)
    new_output = state.output ++ [error_token | inserted]

    {
      :ok,
      hd(new_output),
      [],
      %{
        state
        | contexts: new_contexts,
          output: tl(new_output),
          recent_token: hd(new_output)
      }
    }
  end

  defp emit_pending_error(
         {:missing_context,
          {:interp, kind, _allow, delim, parent_terms, _start, _frags, _saw} = interp_context},
         state
       ) do
    reason = Contexts.missing_terminator_reason(interp_context, state.line, state.column)
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    error_token = {:error_token, meta0, error_payload(reason, state)}

    inserted =
      if state.insert_structural_closers,
        do: [Synthesis.synthesize_end_for_kind(kind, delim, meta0)],
        else: []

    parent_terms_list = parent_terms

    new_scope = scope(state.scope, terminators: parent_terms_list)
    new_contexts = Contexts.drop_first_interp(state.contexts)
    new_output = state.output ++ [error_token | inserted]

    {
      :ok,
      hd(new_output),
      [],
      %{
        state
        | contexts: new_contexts,
          scope: new_scope,
          output: tl(new_output),
          recent_token: hd(new_output)
      }
    }
  end

  defp emit_pending_error({:missing_scope, {start, _meta, _indent} = entry}, state) do
    reason =
      Contexts.missing_scope_terminator_reason(entry, state.line, state.column, state.scope)

    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    error_token = {:error_token, meta0, error_payload(reason, state)}

    scope(terminators: terms) = state.scope

    [_ | rest] = terms
    new_scope = scope(state.scope, terminators: rest)

    inserted =
      if state.insert_structural_closers, do: [{closing_for(start), meta0, nil}], else: []

    new_output = state.output ++ [error_token | inserted]

    {
      :ok,
      hd(new_output),
      [],
      %{
        state
        | scope: new_scope,
          output: tl(new_output),
          recent_token: hd(new_output)
      }
    }
  end

  defp error_payload(%Toxic.Error{} = error, %{error_token_payload: mode}) do
    error = Toxic.Error.safe_validate(error)

    case mode do
      :struct ->
        error

      :tuple ->
        Toxic.Error.safe_to_reason_tuple(error)

      :both ->
        {error, Toxic.Error.safe_to_reason_tuple(error)}
    end
  end
end
