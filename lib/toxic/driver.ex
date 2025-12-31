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
  alias Toxic.Driver.Deferrals
  alias Toxic.Driver.Recovery
  alias Toxic.Driver.Synthesis

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

  @spec new(keyword()) :: Toxic.Driver.t()
  def new(opts \\ []) do
    elixir_compatibility = Keyword.get(opts, :elixir_compatibility, false)
    preserve_comments = Keyword.get(opts, :preserve_comments, false)
    existing_atoms_only = Keyword.get(opts, :existing_atoms_only, false)
    static_atoms_encoder = Keyword.get(opts, :static_atoms_encoder, nil)
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)
    error_mode = Keyword.get(opts, :error_mode, :tolerant)

    error_sync =
      Keyword.get(opts, :error_sync, [
        :semicolon,
        :newline,
        :closer,
        :comma,
        :comment,
        :whitespace
      ])

    error_max_skip = Keyword.get(opts, :error_max_skip, 4096)
    insert_structural_closers = Keyword.get(opts, :insert_structural_closers, true)
    insert_identifier_sanitization = Keyword.get(opts, :insert_identifier_sanitization, true)
    error_token_payload = Keyword.get(opts, :error_token_payload, :struct)
    lexer_backend = Keyword.get(opts, :lexer_backend, :charlist)

    %__MODULE__{
      line: line,
      column: column,
      error_mode: error_mode,
      error_sync: error_sync,
      error_max_skip: error_max_skip,
      insert_structural_closers: insert_structural_closers,
      insert_identifier_sanitization: insert_identifier_sanitization,
      error_token_payload: error_token_payload,
      lexer_backend: lexer_backend,
      scope:
        scope(
          elixir_compatibility: elixir_compatibility,
          preserve_comments: preserve_comments,
          existing_atoms_only: existing_atoms_only,
          static_atoms_encoder: static_atoms_encoder,
          column: column
        )
    }
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
  @spec next(input(), t()) ::
          {:ok, token(), input(), t()}
          | {:eof, t()}
          | {:error, error_reason(), input(), t()}
  def next(rest, %__MODULE__{output: [h | t]} = state) do
    return_token(h, rest, %{state | output: t})
  end

  def next([], %__MODULE__{deferrals: []} = state) do
    case Contexts.pending_error(state) do
      nil ->
        {:eof, state}

      error when state.error_mode == :strict ->
        case error do
          {:missing_interpolation, interp_context} ->
            reason = Contexts.missing_interpolation_reason(interp_context, state)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_context, interp_context} ->
            reason = Contexts.missing_terminator_reason(interp_context, state)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_scope, entry} ->
            reason = Contexts.missing_scope_terminator_reason(entry, state)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}
        end

      error when state.error_mode == :tolerant ->
        emit_pending_error(error, state)
    end
  end

  def next([], %__MODULE__{deferrals: [_h | _t] = deferrals} = state) do
    next([], %{state | deferrals: [], output: Enum.reverse(deferrals)})
  end

  # Binary backend EOF handling
  def next(<<>>, %__MODULE__{lexer_backend: :binary, deferrals: []} = state) do
    case Contexts.pending_error(state) do
      nil ->
        {:eof, state}

      error when state.error_mode == :strict ->
        case error do
          {:missing_interpolation, interp_context} ->
            reason = Contexts.missing_interpolation_reason(interp_context, state)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}

          {:missing_context, interp_context} ->
            reason = Contexts.missing_terminator_reason(interp_context, state)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}

          {:missing_scope, entry} ->
            reason = Contexts.missing_scope_terminator_reason(entry, state)
            {:error, Toxic.Error.to_reason_tuple(reason), <<>>, state}
        end

      error when state.error_mode == :tolerant ->
        emit_pending_error(error, state)
    end
  end

  def next(<<>>, %__MODULE__{lexer_backend: :binary, deferrals: [_h | _t] = deferrals} = state) do
    next(<<>>, %{state | deferrals: [], output: Enum.reverse(deferrals)})
  end

  def next(
        [?} | rest],
        %__MODULE__{
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
    reason = Contexts.mismatched_delimiter_reason(entry, :"}", state)

    case state.error_mode do
      :strict ->
        reason_tuple = Toxic.Error.to_reason_tuple(reason)
        {:error, reason_tuple, rest, state}

      :tolerant ->
        Recovery.emit_error_and_advance(reason, rest, state)
    end
  end

  def next(
        [?} | rest],
        %__MODULE__{
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
        %__MODULE__{
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
    reason = Contexts.mismatched_delimiter_reason(entry, :"}", state)

    case state.error_mode do
      :strict ->
        reason_tuple = Toxic.Error.to_reason_tuple(reason)
        {:error, reason_tuple, rest, state}

      :tolerant ->
        Recovery.emit_error_and_advance(reason, rest, state)
    end
  end

  def next(
        <<?}, rest::binary>>,
        %__MODULE__{
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

  def next(string, %__MODULE__{contexts: [:normal | _], lexer_backend: :charlist} = state) do
    carry_with_recent = state.deferrals ++ List.wrap(state.recent_token)

    result =
      Toxic.NormalTokenizer.next(
        string,
        state.line,
        state.column,
        state.scope,
        carry_with_recent
      )

    case handle_tokenize_result(state, result) do
      {:error, reason, state} ->
        case state.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            Recovery.emit_error_and_advance(reason, string, state)
        end

      {rest, state} ->
        next(rest, state)
    end
  end

  def next(string, %__MODULE__{contexts: [:normal | _], lexer_backend: :binary} = state) do
    carry_with_recent = state.deferrals ++ List.wrap(state.recent_token)

    result =
      Toxic.BinaryNormalTokenizer.next(
        string,
        state.line,
        state.column,
        state.scope,
        carry_with_recent
      )

    case handle_tokenize_result(state, result) do
      {:error, reason, state} ->
        case state.error_mode do
          :strict ->
            reason_tuple = Toxic.Error.to_reason_tuple(reason)
            {:error, reason_tuple, string, state}

          :tolerant ->
            Recovery.emit_error_and_advance(reason, string, state)
        end

      {rest, state} ->
        next(rest, state)
    end
  end

  def next(
        string,
        %__MODULE__{
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
            Recovery.emit_error_and_advance(reason, string, state)
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
              Recovery.emit_error_and_advance(reason, rest, %{
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
        %__MODULE__{
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
            Recovery.emit_error_and_advance(reason, string, state)
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
            <<?( , _::binary>> -> :quoted_paren_identifier_end
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
              Recovery.emit_error_and_advance(reason, rest, %{
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
         state = %__MODULE__{contexts: contexts, deferrals: deferrals, output: output},
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
               {kind, meta(start_line, start_column, line, column, extra + count), extra_value} | t
             ]
         }}

      {{:token, {eol, _meta, _extra} = token}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        new_output = Deferrals.flush(output, deferrals)

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

        new_output = Deferrals.append(output, deferrals_result, output_tokens)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: []
         }}

      {{:token, {:identifier, _, _} = token}, rest, line, column, scope} ->
        new_output = Deferrals.flush(output, deferrals)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: [token]
         }}

      {{:token, token}, rest, line, column, scope} ->
        new_output = Deferrals.append(output, deferrals, [token])

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

        new_output = Deferrals.append(output, deferrals_result, output_tokens)

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: new_output,
             deferrals: []
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

      {{:token_with_eol, token}, rest, line, column, scope} ->
        carry_with_recent =
          case {token, deferrals} do
            {left, [{:eol, _, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        new_output = Deferrals.flush(output, carry_with_recent)

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

        new_output = Deferrals.append(output, deferrals, [start_token])

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
    # Collect current scope terminators and any parent terminators saved in
    # interpolation contexts on the driver's context stack, plus delimiters
    # from string/heredoc/atom/sigil constructs.

    # Read current terminators from scope record
    scope(terminators: current_terms) = driver.scope

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
    context_length = length(driver.contexts)

    context_terms =
      driver.contexts
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
          delimiter_terminator = [{List.to_atom(List.wrap(delim)), nil, 0}]

          parent_terms ++ delimiter_terminator

        {:normal, _index} ->
          # Root :normal context does not have interpolation brace terminator
          []
      end)

    current_terms ++ context_terms
  end

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

  defp emit_pending_error(
         {:missing_interpolation,
          {:interp, kind, _allow, _delim, _parents, _start, _frags, _saw} = interp_context},
         state
       ) do
    reason = Contexts.missing_interpolation_reason(interp_context, state)
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
      %{state | contexts: new_contexts, output: tl(new_output), recent_token: hd(new_output)}
    }
  end

  defp emit_pending_error(
         {:missing_context,
          {:interp, kind, _allow, delim, parent_terms, _start, _frags, _saw} = interp_context},
         state
       ) do
    reason = Contexts.missing_terminator_reason(interp_context, state)
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
    reason = Contexts.missing_scope_terminator_reason(entry, state)
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
      %{state | scope: new_scope, output: tl(new_output), recent_token: hd(new_output)}
    }
  end

  defp error_payload(%Toxic.Error{} = error, %__MODULE__{error_token_payload: mode}) do
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
