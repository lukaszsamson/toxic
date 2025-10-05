defmodule Toxic.Driver do
  import Toxic.Scope
  import Toxic.Token
  import Toxic.CharacterClassifier

  defstruct line: 1,
            column: 1,
            scope: nil,
            contexts: [:normal],
            # Error-tolerant mode controls
            error_mode: :tolerant,
            error_sync: [:semicolon, :newline, :closer, :comma],
            error_max_skip: 4096,
            insert_structural_closers: true,
            insert_identifier_sanitization: true,
            # New: prioritized deferral list for delayed emissions
            # Entries: {:emit_next, token, consume_len, after_action | nil}
            #  - consume_len: non-neg integer to consume from input and advance column
            #  - after_action: {:push_interp, kind, interpolation, delim} | nil
            deferrals: [],
            output: [],
            # Track the most recent token emitted (for carry context)
            recent_token: nil

  # TODO: better type
  @type interp_kind() :: atom()
  @type interp_delim() :: any()
  @type terminators() :: :none | list()
  @type t() :: %__MODULE__{
          line: pos_integer(),
          column: pos_integer(),
          contexts:
            list(
              :normal
              | {:interp, interp_kind(), boolean(), interp_delim(), terminators(),
                 %{line: pos_integer(), column: pos_integer(), token: tuple()}, list(), boolean()}
            ),
          error_mode: :tolerant | :strict,
          error_sync: [:semicolon | :newline | :closer | :comma],
          error_max_skip: non_neg_integer(),
          insert_structural_closers: boolean(),
          insert_identifier_sanitization: boolean(),
          deferrals: list(),
          output: list(),
          recent_token: any(),
          scope: Toxic.Scope.scope()
        }

  def new(opts \\ []) do
    elixir_compatibility = Keyword.get(opts, :elixir_compatibility, false)
    preserve_comments = Keyword.get(opts, :preserve_comments, false)
    existing_atoms_only = Keyword.get(opts, :existing_atoms_only, false)
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)
    error_mode = Keyword.get(opts, :error_mode, :tolerant)
    error_sync = Keyword.get(opts, :error_sync, [:semicolon, :newline, :closer, :comma])
    error_max_skip = Keyword.get(opts, :error_max_skip, 4096)
    insert_structural_closers = Keyword.get(opts, :insert_structural_closers, true)
    insert_identifier_sanitization = Keyword.get(opts, :insert_identifier_sanitization, true)

    %__MODULE__{
      line: line,
      column: column,
      error_mode: error_mode,
      error_sync: error_sync,
      error_max_skip: error_max_skip,
      insert_structural_closers: insert_structural_closers,
      insert_identifier_sanitization: insert_identifier_sanitization,
      scope:
        scope(
          identifier_tokenizer: String.Tokenizer,
          elixir_compatibility: elixir_compatibility,
          preserve_comments: preserve_comments,
          existing_atoms_only: existing_atoms_only
        )
    }
  end

  @doc """
  Recover from a driver-level error in tolerant mode by emitting an error token
  (and optionally structural insertions) and advancing to the next sync point.

  Returns same shape as next/2: {:ok, token, rest, new_driver}.
  """
  def recover(rest, %__MODULE__{error_mode: :tolerant} = state, reason) do
    emit_error_and_advance(reason, rest, state)
  end

  def next(rest, %__MODULE__{output: [h | t]} = state) do
    return_token(h, rest, %{state | output: t})
  end

  def next([], %__MODULE__{deferrals: []} = state) do
    case pending_error(state) do
      nil ->
        {:eof, state}

      error when state.error_mode == :strict ->
        case error do
          {:missing_interpolation, interp_context} ->
            reason = missing_interpolation_reason(interp_context, state)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_context, interp_context} ->
            reason = missing_terminator_reason(interp_context, state)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}

          {:missing_scope, entry} ->
            reason = missing_scope_terminator_reason(entry, state)
            {:error, Toxic.Error.to_reason_tuple(reason), [], state}
        end

      error when state.error_mode == :tolerant ->
        emit_pending_error(error, state)
    end
  end

  def next([], %__MODULE__{deferrals: [_h | _t] = deferrals} = state) do
    next([], %{state | deferrals: [], output: Enum.reverse(deferrals)})
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
    reason = mismatched_delimiter_reason(entry, :"}", state)
    {:error, Toxic.Error.to_reason_tuple(reason), rest, state}
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

  def next(string, %__MODULE__{contexts: [:normal | _] = _contexts} = state) do
    carry_with_recent = state.deferrals ++ List.wrap(state.recent_token)

    result =
      Toxic.Tokenizer.tokenize_single(
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
            reason_tuple =
              reason
              |> Toxic.Error.ensure_struct()
              |> Toxic.Error.to_reason_tuple()

            {:error, reason_tuple, string, state}

          :tolerant -> emit_error_and_advance(reason, string, state)
        end

      {rest, state} ->
        next(rest, state)
    end
  end

  def next(
        string,
        %__MODULE__{
          contexts: [
            {:interp, kind, interpolation_allowed?, delim, parent_terminators, start_info,
             fragments, saw_interp}
            | contexts_rest
          ]
        } =
          state
      ) do
    case Toxic.Interpolation.tokenize_single(
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
            reason_tuple =
              reason
              |> Toxic.Error.ensure_struct()
              |> Toxic.Error.to_reason_tuple()

            {:error, reason_tuple, string, state}

          :tolerant -> emit_error_and_advance(reason, string, state)
        end

      {:fragment, meta(start_line, start_column, _end_line, end_column, extra), binary_part, rest,
       line, column, scope} ->
        {binary_part, line} =
          case state.recent_token do
            {kind, _, _} when kind in [:bin_heredoc_start, :list_heredoc_start] ->
              "\n" <> binary_part_no_newline = binary_part
              {binary_part_no_newline, line - 1}

            {:sigil_start, _, _, delim} when delim in ["\"\"\"", "'''"] ->
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
        end_token = {:sigil_end, meta, delim, indent}

        {rest, modifiers} = Toxic.Sigil.collect_modifiers(rest)
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
            Toxic.Scope.prepend_warning(
              start_info.line,
              start_info.column,
              ~c"single-quoted string represent charlists. Use ~c''' if you indeed want a charlist or use \"\"\" instead",
              scope
            )
          else
            scope
          end

        return_token({end_token_type, meta, delim, indent}, rest, %{
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
          case __MODULE__.is_unnecessary_quote(
                 Enum.reverse(fragments),
                 saw_interp,
                 :quoted_identifier,
                 scope
               ) do
            {true, content} ->
              __MODULE__.maybe_warn_unnecessary_quote(
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
              case __MODULE__.is_unnecessary_quote(
                     Enum.reverse(fragments),
                     saw_interp,
                     end_token_type,
                     scope
                   ) do
                {true, content} ->
                  # Quotes are unnecessary - emit only this warning
                  __MODULE__.maybe_warn_unnecessary_quote(
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
                    Toxic.Scope.prepend_warning(
                      start_info.line,
                      start_info.column,
                      ~c"single quotes around keywords are deprecated. Use double quotes instead",
                      scope
                    )
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
                  # TODO: no test coverage
                  :atom_safe_end

                :atom_unsafe ->
                  :atom_unsafe_end

                _ ->
                  :bin_string_end
              end

            # Check for unnecessary quotes on atoms and emit charlist warning for charlists
            updated_scope =
              if end_token_type in [:atom_safe_end, :atom_unsafe_end] do
                case __MODULE__.is_unnecessary_quote(
                       Enum.reverse(fragments),
                       saw_interp,
                       kind,
                       scope
                     ) do
                  {true, content} ->
                    # For atoms, extract the token start column from the start_token meta
                    # The start_token has the : position, but start_info.column points to the delimiter
                    {{_start_line, token_start_col}, {_end_line, _end_col}, _extra} =
                      elem(start_info.token, 1)

                    __MODULE__.maybe_warn_unnecessary_quote(
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
                  Toxic.Scope.prepend_warning(
                    start_info.line,
                    start_info.column,
                    ~c"using single-quoted strings to represent charlists is deprecated.\n" ++
                      ~c"Use ~c\"\" if you indeed want a charlist or use \"\" instead.\n" ++
                      ~c"You may run \"mix format --migrate\" to change all single-quoted\n" ++
                      ~c"strings to use the ~c sigil and fix this warning.",
                    scope
                  )
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
          reason = interpolation_in_quoted_identifier_reason(start_info.line, start_info.column, delim)
          {:error, Toxic.Error.to_reason_tuple(reason), rest, state}
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
        [{kind, meta(start_line, start_column, _end_line, _end_column, _extra)} | t] = deferrals

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [{kind, meta(start_line, start_column, line, column, 0)} | t]
         }}

      {:increase_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, extra)} | t] = deferrals

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [{kind, meta(start_line, start_column, line, column, extra + 1)} | t]
         }}

      {{:token, {eol, _meta} = token}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: output ++ Enum.reverse(deferrals),
             deferrals: [token]
         }}

      {:transform_into_do_identifier, rest, line, column, scope} ->
        updated_token =
          case deferrals do
            [{:identifier, meta, name}] -> {:do_identifier, meta, name}
            [{:quoted_identifier_end, meta, name}] -> {:quoted_do_identifier_end, meta, name}
          end

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: [updated_token],
             deferrals: []
         }}

      {{:token, {:identifier, _, _} = token}, rest, line, column, scope} ->
        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: output ++ Enum.reverse(deferrals),
             deferrals: [token]
         }}

      {{:token, token}, rest, line, column, scope} ->
        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             deferrals: [],
             output: output ++ Enum.reverse(deferrals) ++ [token]
         }}

      {{:dual_op_identifier, token}, rest, line, column, scope} ->
        updated_token =
          case deferrals do
            [{:identifier, meta, name}] -> {:op_identifier, meta, name}
            [{:quoted_identifier_end, meta, name}] -> {:quoted_op_identifier_end, meta, name}
          end

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: [updated_token, token],
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
            {left, [{:eol, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope,
             output: output ++ Enum.reverse(carry_with_recent),
             deferrals: []
         }}

      {{:switch_to_interp, start_token, interp_kind, interpolation_allowed?, delimiter}, rest,
       line, column, scope = scope(terminators: terminators)} ->
        start_info = compute_start_info(start_token, delimiter, line, column)

        contexts =
          [
            {:interp, interp_kind, interpolation_allowed?, delimiter, terminators, start_info, [],
             false}
            | contexts
          ]

        {rest,
         %{
           state
           | line: line,
             column: column,
             scope: scope(scope, terminators: []),
             output: output ++ Enum.reverse([start_token | deferrals]),
             deferrals: [],
             contexts: contexts
         }}
    end
  end

  defp compute_start_info(start_token, delimiter, line, column) do
    {{_meta_start_line, _meta_start_column}, {meta_end_line, meta_end_column}, _extra} =
      elem(start_token, 1)

    delimiter_length = delimiter_length(delimiter)

    cond do
      # TODO: this seems too complicated
      line == meta_end_line and column - delimiter_length >= 1 ->
        %{line: meta_end_line, column: column - delimiter_length, token: start_token}

      true ->
        base_column = meta_end_column - delimiter_length

        %{line: meta_end_line, column: base_column, token: start_token}
    end
  end

  defp pending_error(%__MODULE__{contexts: contexts, scope: scope} = _state) do
    cond do
      # Drain innermost structural scopes first (e.g., missing ")" from an open "(")
      entry = find_missing_scope_terminator(scope) ->
        {:missing_scope, entry}

      # Then close any open interpolation braces
      interp = find_missing_interpolation(contexts) ->
        {:missing_interpolation, interp}

      # Finally, close the surrounding string/sigil/quoted identifier contexts
      context = find_missing_context(contexts) ->
        {:missing_context, context}

      true ->
        nil
    end
  end

  defp find_missing_interpolation([:normal, {:interp, _, _, _, _, _, _, _} = interp | _]),
    do: interp

  defp find_missing_interpolation([_ | rest]), do: find_missing_interpolation(rest)
  defp find_missing_interpolation(_), do: nil

  defp find_missing_context([{:interp, _, _, _, _, _, _, _} = interp | _]), do: interp
  defp find_missing_context([_ | rest]), do: find_missing_context(rest)
  defp find_missing_context(_), do: nil

  # TODO: eex support, remove?
  defp find_missing_scope_terminator(scope(terminators: :none)), do: nil
  defp find_missing_scope_terminator(scope(terminators: [])), do: nil
  defp find_missing_scope_terminator(scope(terminators: [entry | _])), do: entry

  defp missing_terminator_reason(
         {:interp, kind, _allowed?, delim, _parents,
          %{line: start_line, column: start_column} = start_info, _fragments, _saw_interp},
         %__MODULE__{line: end_line, column: end_column}
       ) do
    delim_chars = delimiter_charlist(delim)
    opening_atom = delimiter_atom(delim_chars)
    delimiter_length = delimiter_length(delim)

    {resolved_end_line, resolved_end_column} =
      if start_line == end_line do
        {start_line, start_column + delimiter_length}
      else
        {end_line, end_column}
      end

    code =
      case kind do
        k when k in [:bin_heredoc, :list_heredoc] -> :heredoc_missing_terminator
        _ -> :string_missing_terminator
      end

    %Toxic.Error{
      code: code,
      domain: if(code == :heredoc_missing_terminator, do: :heredoc, else: :string),
      token_display: nil,
      details: %{
        opening_delimiter: opening_atom,
        expected_delimiter: opening_atom,
        line: start_line,
        column: start_column,
        end_line: resolved_end_line,
        end_column: resolved_end_column,
        suffix_iolist: context_suffix(kind, delim, start_info)
      }
    }
  end

  defp missing_interpolation_reason(
         {:interp, kind, _allowed?, delim, _parents,
          %{line: start_line, column: start_column} = start_info, _fragments, _saw_interp},
         %__MODULE__{line: end_line, column: end_column}
       ) do
    delim_chars = delimiter_charlist(delim)
    opening_atom = delimiter_atom(delim_chars)

    delimiter_length = delimiter_length(delim)

    {resolved_end_line, resolved_end_column} =
      if start_line == end_line do
        {start_line, start_column + delimiter_length}
      else
        {end_line, end_column}
      end

    %Toxic.Error{
      code: :interpolation_missing_terminator,
      domain: :interpolation,
      token_display: nil,
      details: %{
        opening_delimiter: opening_atom,
        expected_delimiter: opening_atom,
        start_line: start_line,
        start_column: start_column,
        end_line: resolved_end_line,
        end_column: resolved_end_column,
        suffix_iolist: context_suffix(kind, delim, start_info)
      }
    }
  end

  defp missing_scope_terminator_reason(
         {start, meta, _indentation} = entry,
         %__MODULE__{line: end_line, column: end_column, scope: scope} = _state
       ) do
    closing = closing_for(start)

    hint = missing_scope_hint(entry, closing, scope)

    {{start_line, start_column}, _end_pos, _extra} = meta

    %Toxic.Error{
      code: :terminator_missing_closer,
      domain: :terminator,
      token_display: nil,
      details: %{
        opening_delimiter: start,
        expected_delimiter: closing,
        line: start_line,
        column: start_column,
        end_line: end_line,
        end_column: end_column,
        hint_iolist: hint
      }
    }
  end

  defp mismatched_delimiter_reason({start, meta, _indent}, closing, %__MODULE__{
         line: end_line,
         column: end_column
       }) do
    expected = closing_for(start)
    is_end = closing == :end
    closing_chars = terminator_chars(closing)

    {{start_line, start_column}, _end_pos, _extra} = meta

    code = if is_end, do: :reserved_unexpected_end, else: :terminator_mismatched_closer
    token_display = if is_end, do: ~c"end", else: closing_chars

    %Toxic.Error{
      code: code,
      domain: if(is_end, do: :reserved, else: :terminator),
      token_display: token_display,
      position: {{start_line, start_column}, {end_line, end_column}},
      details: %{
        opening_delimiter: start,
        closing_delimiter: closing,
        expected_delimiter: expected
      }
    }
  end

  defp context_suffix(:sigil, delim, %{line: line, token: {:sigil_start, _meta, sigil_atom, _}}) do
    sigil_name =
      sigil_atom
      |> Atom.to_string()
      |> String.replace_prefix("sigil_", "")
      |> String.to_charlist()

    sigil_label = [?~ | sigil_name]
    delimiter_chars = delimiter_charlist(delim)

    :io_lib.format(~c" (for sigil ~ts~ts starting at line ~B)", [
      sigil_label,
      delimiter_chars,
      line
    ])
  end

  defp context_suffix(:quoted_identifier, _delim, %{line: line}) do
    :io_lib.format(~c" (for function name starting at line ~B)", [line])
  end

  defp context_suffix(kind, _delim, %{line: line}) when kind in [:atom_safe, :atom_unsafe] do
    :io_lib.format(~c" (for atom starting at line ~B)", [line])
  end

  defp context_suffix(kind, _delim, %{line: line}) when kind in [:bin_heredoc, :list_heredoc] do
    :io_lib.format(~c" (for heredoc starting at line ~B)", [line])
  end

  defp context_suffix(_, _delim, %{line: line}) do
    :io_lib.format(~c" (for string starting at line ~B)", [line])
  end

  defp interpolation_in_quoted_identifier_reason(start_line, start_column, delim) do
    %Toxic.Error{
      code: :interpolation_not_allowed_in_quoted_identifier,
      domain: :interpolation,
      token_display: delimiter_charlist(delim),
      details: %{start_line: start_line, start_column: start_column}
    }
  end

  defp delimiter_charlist(delim) when is_integer(delim), do: [delim]

  # TODO: no coverage, not possible?
  # defp delimiter_charlist(delim) when is_binary(delim) do
  #   String.to_charlist(delim)
  # end

  defp delimiter_charlist(delim) when is_list(delim), do: delim

  defp delimiter_atom(chars) do
    chars
    |> List.flatten()
    |> List.to_atom()
  end

  defp delimiter_length(delim) do
    delim
    |> delimiter_charlist()
    |> length()
  end

  defp terminator_chars(delimiter) when is_atom(delimiter) do
    delimiter
    |> Atom.to_string()
    |> String.to_charlist()
  end

  defp missing_scope_hint({_start, _meta, _indent}, _closing, scope(mismatch_hints: [])), do: []

  defp missing_scope_hint({start, _meta, _indent}, closing, scope(mismatch_hints: mismatch_hints)) do
    # Check for hint about mismatched terminator based on indentation
    case :lists.keyfind(start, 1, mismatch_hints) do
      {^start, hint_meta, _indentation} ->
        {{hint_line, _hint_column}, _, _} = hint_meta

        :io_lib.format(
          ~c"\nhint: it looks like the \"~ts\" on line ~B does not have a matching \"~ts\"",
          [Atom.to_string(start), hint_line, Atom.to_string(closing)]
        )

      false ->
        []
    end
  end

  # Helper to return a token and update recent_token in state
  defp return_token(token, rest, state) do
    {:ok, token, rest, %{state | recent_token: token}}
  end

  defp emit_pending_error({:missing_interpolation, {:interp, kind, _allow, _delim, _parents, _start, _frags, _saw} = interp_context}, state) do
    reason = missing_interpolation_reason(interp_context, state)
    error_struct = Toxic.Error.ensure_struct(reason)
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    error_token = {:error_token, meta0, error_struct}

    inserted = if state.insert_structural_closers, do: [{:end_interpolation, meta0, kind}], else: []

    # Pop the leading :normal that represents being inside interpolation, but
    # keep the parent {:interp, ...} context so we can subsequently emit the
    # missing string/sigil/atom terminator on the next pending error.
    new_contexts = drop_first_normal_before_interp(state.contexts)
    new_output = state.output ++ [error_token | inserted]
    {:ok, hd(new_output), [], %{state | contexts: new_contexts, output: tl(new_output), recent_token: hd(new_output)}}
  end

  defp emit_pending_error({:missing_context, {:interp, kind, _allow, delim, parent_terms, _start, _frags, _saw} = interp_context}, state) do
    reason = missing_terminator_reason(interp_context, state)
    error_struct = Toxic.Error.ensure_struct(reason)
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    error_token = {:error_token, meta0, error_struct}

    inserted = if state.insert_structural_closers, do: [synthesize_end_for_kind(kind, delim, meta0)], else: []

    parent_terms_list = case parent_terms do :none -> []; list when is_list(list) -> list end
    new_scope = scope(state.scope, terminators: parent_terms_list)
    new_contexts = drop_first_interp(state.contexts)
    new_output = state.output ++ [error_token | inserted]
    {:ok, hd(new_output), [], %{state | contexts: new_contexts, scope: new_scope, output: tl(new_output), recent_token: hd(new_output)}}
  end

  defp emit_pending_error({:missing_scope, {start, _meta, _indent} = entry}, state) do
    reason = missing_scope_terminator_reason(entry, state)
    error_struct = Toxic.Error.ensure_struct(reason)
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    error_token = {:error_token, meta0, error_struct}

    # Pop one scope terminator
    scope(terminators: terms) = state.scope
    new_terms = case terms do [] -> []; [_ | rest] -> rest end
    new_scope = scope(state.scope, terminators: new_terms)

    inserted = if state.insert_structural_closers, do: [{closing_for(start), meta0}], else: []

    new_output = state.output ++ [error_token | inserted]
    {:ok, hd(new_output), [], %{state | scope: new_scope, output: tl(new_output), recent_token: hd(new_output)}}
  end

  defp drop_first_interp([{:interp, _, _, _, _, _, _, _} | rest]), do: rest
  defp drop_first_interp([head | tail]), do: [head | drop_first_interp(tail)]
  defp drop_first_interp([]), do: []

  # Drop the first :normal that immediately precedes an interpolation frame,
  # preserving the interpolation frame itself. This mirrors how a real '}'
  # would pop the :normal frame and keep the parent {:interp, ...} on stack.
  defp drop_first_normal_before_interp([:normal, {:interp, _, _, _, _, _, _, _} = interp | rest]),
    do: [interp | rest]

  defp drop_first_normal_before_interp([head | tail]),
    do: [head | drop_first_normal_before_interp(tail)]

  defp drop_first_normal_before_interp(list), do: list

  defp synthesize_end_for_kind(:sigil, delim, meta), do: {:sigil_end, meta, delim, 0}
  defp synthesize_end_for_kind(:bin_heredoc, delim, meta), do: {:bin_heredoc_end, meta, delim, 0}
  defp synthesize_end_for_kind(:list_heredoc, delim, meta), do: {:list_heredoc_end, meta, delim, 0}
  defp synthesize_end_for_kind(:quoted_identifier, delim, meta), do: {:quoted_identifier_end, meta, delim}
  defp synthesize_end_for_kind(:charlist, delim, meta), do: {:list_string_end, meta, delim}
  defp synthesize_end_for_kind(:string, delim, meta), do: {:bin_string_end, meta, delim}
  defp synthesize_end_for_kind(:atom_safe, delim, meta), do: {:atom_safe_end, meta, delim}
  defp synthesize_end_for_kind(:atom_unsafe, delim, meta), do: {:atom_unsafe_end, meta, delim}

  # Phase 1 tolerant mode helpers
  defp emit_error_and_advance(reason, rest, state) do
    error = case reason do %Toxic.Error{} = e -> e; other -> Toxic.Error.ensure_struct(other) end
    {def_rest, def_line, def_col} = scan_to_sync(rest, state)

    # Phase 4: Context-specific minimal recovery (override default scan)
    {new_rest, new_line, new_column, recovery_tokens, scope_after_pre} =
      adjust_recovery(error, rest, state, def_rest, def_line, def_col)

    # Separate pre_inserted (before error) from post_inserted (after error)
    {pre_inserted, post_inserted} = Enum.split_with(recovery_tokens, fn
      {:post_error, _} -> false
      _ -> true
    end)
    # Unwrap post_error markers
    post_inserted = Enum.map(post_inserted, fn {:post_error, tok} -> tok end)

    # Always make progress
    {new_rest, new_line, new_column} =
      if new_line == state.line and new_column == state.column do
        consume_one(rest, state)
      else
        {new_rest, new_line, new_column}
      end

    error_meta = meta(state.line, state.column, new_line, new_column, nil)
    error_token = {:error_token, error_meta, error}

    # Optionally synthesize structural tokens for delimiter errors
    {synth_side, inserted_struct, scope_after_insert} =
      if state.insert_structural_closers do
        synthesize_from_reason(error, %{state | scope: scope_after_pre})
      else
        {:none, [], scope_after_pre}
      end

    # For mismatched closers, also synthesize an opener for the actual closer
    # so the stream shows `(:)`. We'll pop it immediately after emitting the
    # actual closer below to keep the stack balanced.
    actual_closer = actual_closer_from_reason(error)
    {extra_synth_openers, scope_after_extra} =
      case {error.code, actual_closer} do
        {:terminator_mismatched_closer, closer} when closer != nil ->
          case opening_for_closer(closer) do
            nil -> {[], scope_after_insert}
            opening ->
              case synthesize_opening(opening, %{state | scope: scope_after_insert}) do
                {:ok, tok, new_scope} ->
                  tok = maybe_tag_zero_len(tok, state)
                  {[tok], new_scope}
                _ -> {[], scope_after_insert}
              end
          end
        _ -> {[], scope_after_insert}
      end

    scope_for_state =
      if synth_side == :opener or extra_synth_openers != [] do
        # Pop one opener we just pushed (either from unexpected closer case,
        # or the extra opener synthesized for mismatched closer).
        scope(terminators: [_ | popped_terms]) = scope_after_extra
        scope(scope_after_extra, terminators: popped_terms)
      else
        scope_after_extra
      end

    {pre_synth, post_synth} =
      case synth_side do
        # For unexpected closers, synthesize opener AFTER error (per finalized plan/tests)
        :opener -> {[], inserted_struct ++ extra_synth_openers}
        # For mismatches/missing closers, synthesize closer AFTER error,
        # and also include any extra synthesized opener for the actual closer
        :closer -> {[], inserted_struct ++ extra_synth_openers}
        _ -> {[], []}
      end

    # If this error originated from encountering a closer in the input, emit the
    # actual closer token after any synthesized tokens so the stream includes it
    # even when synthesis is disabled. This preserves expected [:error_token, synthetic_opener?, closer]
    # ordering. Use zero-length meta at the current position to avoid position drift.
    post_actual_closer =
      case actual_closer do
        nil -> []
        closer_atom -> [{closer_atom, meta(new_line, new_column, new_line, new_column, nil)}]
      end

    # If the error span crossed a newline, drop any deferred :eol to avoid
    # emitting a stale end-of-line prior to the error token.
    deferrals_to_emit =
      if new_line > state.line do
        Enum.reject(state.deferrals, fn tok -> elem(tok, 0) == :eol end)
      else
        state.deferrals
      end

    # Flush deferrals BEFORE error to preserve ordering; merge synthesized tokens on proper sides
    # Order: deferrals + pre_inserted + pre_synth + error + post_inserted + post_synth
    new_output =
      state.output ++
        Enum.reverse(deferrals_to_emit) ++
        pre_inserted ++ pre_synth ++ [error_token] ++ post_inserted ++ post_synth ++ post_actual_closer

    new_state = %{
      state
      | line: new_line,
        column: new_column,
        deferrals: [],
        output: new_output,
        scope: scope_for_state
    }

    # Return next token in output (could be a flushed deferral, then error token)
    next(new_rest, new_state)
  end

  # Phase 4: adjust scan target and optionally insert context-specific tokens
  # Code-based recovery only; no message parsing
  defp adjust_recovery(%Toxic.Error{domain: domain, code: code, details: details} = err, rest, state, def_rest, def_line, def_col) do
    case {domain, code} do
      {:reserved, :reserved_unexpected_end} ->
        # Consume the "end" keyword and an immediate newline if present
        case rest do
          [?e, ?n, ?d, ?\n | tail] -> {tail, state.line + 1, 1, [], state.scope}
          [?e, ?n, ?d, ?\r, ?\n | tail] -> {tail, state.line + 1, 1, [], state.scope}
          [?e, ?n, ?d | tail] -> {tail, state.line, state.column + 3, [], state.scope}
          _ -> {def_rest, def_line, def_col, [], state.scope}
        end

      {:alias, :alias_unexpected_paren} ->
        case rest do
          [?( | tail] ->
            # Pre-insert "(" token before error and consume it from input.
            meta_paren = meta(state.line, state.column, state.line, state.column + 1, nil)
            paren_token = {:"(", meta_paren}

            # Also push the opening paren onto the terminator stack so the
            # subsequent ")" is properly matched by normal tokenization.
            {:ok, _tok, new_scope} = synthesize_opening(:"(", state)

            {tail, state.line, state.column + 1, [paren_token], new_scope}

          _ ->
            {def_rest, def_line, def_col, [], state.scope}
        end

      {:vc, :vc_merge_conflict_marker} ->
        # Consume the newline at end of the conflict marker line so the error
        # span covers the whole line and does not emit a stale :eol before it.
        case def_rest do
          [?\n | new_rest] -> {new_rest, state.line + 1, 1, [], state.scope}
          [?\r, ?\n | new_rest] -> {new_rest, state.line + 1, 1, [], state.scope}
          _ -> {def_rest, def_line, def_col, [], state.scope}
        end

      {_, :unexpected_token} ->
        # For generic unexpected tokens, do not scan ahead. Consume exactly one
        # grapheme to bound the error span and immediately continue.
        {new_rest, new_line, new_col} = consume_one(rest, state)
        {new_rest, new_line, new_col, [], state.scope}

      {_, :keyword_missing_space_after_colon} ->
        # Emit the identifier before ':' as a valid token, then consume ':' and
        # continue with the remainder. This preserves expected ordering
        # [:identifier, :error_token, ...].
        {id_chars, remainder} = Enum.split_while(rest, fn ch -> ch != ?: end)

        case remainder do
          [?: | tail] when id_chars != [] ->
            id_token = sanitize_identifier_from_chars(id_chars, state.line, state.column)
            consumed_len = length(id_chars) + 1
            {tail, state.line, state.column + consumed_len, [id_token], state.scope}

          _ ->
            {def_rest, def_line, def_col, [], state.scope}
        end

      {_, :map_invalid_open_delimiter} ->
        case rest do
          [?% | _] ->
            meta_percent = meta(state.line, state.column, state.line, state.column + 1, nil)
            percent_token = {:%, meta_percent}
            rest_after_percent = tl(rest)

            {rest_no_ws, l_after, c_after} =
              consume_leading_spaces(rest_after_percent, state.line, state.column + 1)

            {rest_no_ws, l_after, c_after, [percent_token], state.scope}
          _ -> {def_rest, def_line, def_col, [], state.scope}
        end

      {_, :string_missing_terminator} ->
        if Map.get(details, :escape_at_eof?, false) do
          case def_rest do
            [?\n | new_rest] -> {new_rest, def_line + 1, 1, [], state.scope}
            [?\r, ?\n | new_rest] -> {new_rest, def_line + 1, 1, [], state.scope}
            _ -> {def_rest, def_line, def_col, [], state.scope}
          end
        else
          {def_rest, def_line, def_col, [], state.scope}
        end

      {_, :heredoc_invalid_header} ->
        meta_end = meta(state.line, state.column, state.line, state.column, nil)

        # Infer end token from delimiter in token_display (already set)
        end_token =
          case List.wrap(err.token_display) do
            [?', ?', ?'] = delim -> {:list_heredoc_end, meta_end, delim, 0}
            [?", ?", ?"] = delim -> {:bin_heredoc_end, meta_end, delim, 0}
            _ -> nil
          end

        inserts = if end_token, do: [{:post_error, end_token}], else: []
        {def_rest, def_line, def_col, inserts, state.scope}

      {:identifier, _code} ->
        if state.insert_identifier_sanitization do
          span_chars = take_prefix_until(rest, def_rest)
          id_token = sanitize_identifier_from_chars(span_chars, state.line, state.column)
          {def_rest, def_line, def_col, [{:post_error, id_token}], state.scope}
        else
          {def_rest, def_line, def_col, [], state.scope}
        end

      # P1: Minimal recovery for simple lexical errors from the main tokenizer
      {:tokenizer, _code} ->
        {new_rest, new_line, new_col} = consume_one(rest, state)
        {new_rest, new_line, new_col, [], state.scope}

      {_, _} ->
        cond do
          ternary_missing_slash?(rest) ->
            meta_op = meta(state.line, state.column, state.line, state.column + 4, nil)
            op_token = {:identifier, meta_op, :..//}

            {Enum.drop(rest, 4), state.line, state.column + 4, [{:post_error, op_token}],
             state.scope}

          consecutive_semicolons?(rest) ->
            meta_semi = meta(state.line, state.column + 1, state.line, state.column + 2, nil)
            semi_token = {:";", meta_semi}
            {Enum.drop(rest, 2), state.line, state.column + 2, [semi_token], state.scope}

          true ->
            {def_rest, def_line, def_col, [], state.scope}
        end
    end
  end

  defp sanitize_identifier_from_chars(chars, line, col) do
    # Normalize original erroneous identifier and build ASCII-friendly skeleton
    bin = Toxic.Util.characters_to_binary(chars)
    skeleton =
      try do
        String.Tokenizer.Security.confusable_skeleton(bin)
      rescue
        _ -> bin
      end

    nfkc = :unicode.characters_to_nfkc_list(skeleton)
    filtered =
      nfkc
      |> Enum.map(fn c -> if allowed_ident_char?(c), do: c, else: ?_ end)
      |> Enum.take(255)
      |> ensure_ident_start()

    meta_id = meta(line, col, line, col + length(filtered), filtered)
    id_atom = List.to_atom(filtered)
    {:identifier, meta_id, id_atom}
  end

  # Take the prefix list elements of `list` up to the exact `tail` list identity.
  # If `tail` is not a suffix of `list`, returns all of `list`.
  defp take_prefix_until(list, tail), do: do_take_prefix_until(list, tail, [])

  defp do_take_prefix_until(list, list, acc), do: Enum.reverse(acc)
  defp do_take_prefix_until([h | t], tail, acc), do: do_take_prefix_until(t, tail, [h | acc])
  defp do_take_prefix_until([], _tail, acc), do: Enum.reverse(acc)

  defp allowed_ident_char?(c) when c in ?0..?9, do: true
  defp allowed_ident_char?(c) when c in ?A..?Z, do: true
  defp allowed_ident_char?(c) when c in ?a..?z, do: true
  defp allowed_ident_char?(?_ ), do: true
  defp allowed_ident_char?(_), do: false

  defp ensure_ident_start([]), do: [?x]
  defp ensure_ident_start([h | _] = list) when h in ?A..?Z or h in ?a..?z or h == ?_, do: list
  defp ensure_ident_start(list), do: [?_ | list]

  defp ternary_missing_slash?(rest) do
    case rest do
      [?. , ?., ?/, ?/ | tail] ->
        case tail do
          [?/ | _] -> false
          _ -> true
        end
      _ -> false
    end
  end

  defp consecutive_semicolons?([?;, ?; | _]), do: true
  defp consecutive_semicolons?(_), do: false

  defp consume_leading_spaces(rest, line, column) do
    consume_leading_spaces(rest, line, column, 0)
  end

  defp consume_leading_spaces([?\\, ?\n | tail], line, _column, count) do
    consume_leading_spaces(tail, line + 1, 1, count + 1)
  end

  defp consume_leading_spaces([?\\, ?\r, ?\n | tail], line, _column, count) do
    consume_leading_spaces(tail, line + 1, 1, count + 1)
  end

  defp consume_leading_spaces([ch | tail], line, column, count) when ch in [?\t, ?\f, ?\v, 32] do
    consume_leading_spaces(tail, line, column + 1, count + 1)
  end

  defp consume_leading_spaces(rest, line, column, _count) do
    {rest, line, column}
  end

  defp consume_one(rest, state) do
    case :unicode_util.gc(rest) do
      [cluster | new_rest] when is_list(cluster) ->
        {line, col} = advance_pos_cluster(cluster, state.line, state.column)
        {new_rest, line, col}

      [codepoint | new_rest] when is_integer(codepoint) ->
        {line, col} = advance_pos(codepoint, state.line, state.column)
        {new_rest, line, col}

      [] ->
        {[], state.line, state.column}
    end
  end

  defp scan_to_sync(rest, state) do
    do_scan_to_sync(rest, state, 0)
  end

  defp do_scan_to_sync(rest, state, scanned) when scanned >= state.error_max_skip do
    # Fallback: consume a single codepoint
    consume_one(rest, state)
  end

  defp do_scan_to_sync([], state, _scanned), do: {[], state.line, state.column}

  defp do_scan_to_sync(list = [h | _t], state, scanned) do
    # Compute stop conditions
    stop? =
      stop_at_semicolon?(h, state) or stop_at_newline?(list) or stop_at_comma?(h, state) or
        stop_at_comment?(h) or stop_at_whitespace?(h) or stop_at_closer?(list, state)

    if stop? do
      {list, state.line, state.column}
    else
      # advance by one grapheme cluster and continue
      case :unicode_util.gc(list) do
        [cluster | rest2] when is_list(cluster) ->
          {next_line, next_col} = advance_pos_cluster(cluster, state.line, state.column)
          do_scan_to_sync(rest2, %{state | line: next_line, column: next_col}, scanned + 1)

        [codepoint | rest2] when is_integer(codepoint) ->
          {next_line, next_col} = advance_pos(codepoint, state.line, state.column)
          do_scan_to_sync(rest2, %{state | line: next_line, column: next_col}, scanned + 1)

        [] ->
          {[], state.line, state.column}
      end
    end
  end

  defp advance_pos(?\n, line, _col), do: {line + 1, 1}
  defp advance_pos(_ch, line, col), do: {line, col + 1}

  defp advance_pos_cluster(cluster, line, col) do
    if Enum.any?(cluster, &(&1 == ?\n)) do
      {line + 1, 1}
    else
      {line, col + 1}
    end
  end

  defp stop_at_semicolon?(ch, %__MODULE__{error_sync: sync}) do
    :semicolon in sync and ch == ?;
  end

  defp stop_at_comma?(ch, %__MODULE__{error_sync: sync}) do
    :comma in sync and ch == ?,
  end

  defp stop_at_comment?(ch), do: ch == ?#

  defp stop_at_whitespace?(h), do: is_horizontal_space(h)

  defp stop_at_newline?([?\n | _]), do: true
  defp stop_at_newline?([?\r, ?\n | _]), do: true
  defp stop_at_newline?(_), do: false

  defp stop_at_closer?(rest, %__MODULE__{error_sync: sync} = state) do
    if :closer in sync do
      case current_terminators(state) do
        [{start_token, _meta, _indent} | _] ->
          expected = closing_for(start_token)
          closer_starts_with?(rest, expected)

        _ ->
          false
      end
    else
      false
    end
  end

  defp closer_starts_with?(list, :")"), do: starts_with_char?(list, ?))
  defp closer_starts_with?(list, :"]"), do: starts_with_char?(list, ?])
  defp closer_starts_with?(list, :"}"), do: starts_with_char?(list, ?})
  defp closer_starts_with?(list, :">>"), do: starts_with_list?(list, [?>, ?>])
  defp closer_starts_with?(list, :end), do: starts_with_list?(list, ~c"end")
  defp closer_starts_with?(list, expected) when is_atom(expected),
    do: starts_with_list?(list, terminator_chars(expected))
  defp closer_starts_with?(_list, _other), do: false

  defp starts_with_char?([h | _], ch), do: h == ch
  defp starts_with_char?(_, _), do: false

  defp starts_with_list?(_list, []), do: true
  defp starts_with_list?([h | t1], [h | t2]), do: starts_with_list?(t1, t2)
  defp starts_with_list?(_, _), do: false

  @doc """
  Get the current terminator stack.
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

  # Helper functions for unnecessary quote warning

  @doc false
  def is_unnecessary_quote(_fragments, saw_interpolation?, _kind, _scope) when saw_interpolation?,
    do: false

  def is_unnecessary_quote(fragments, false, kind, scope) do
    case fragments do
      [single_fragment] ->
        # We have exactly one fragment, check if it's a valid identifier
        content = IO.iodata_to_binary(single_fragment)
        check_identifier_validity(content, kind, scope)

      _ ->
        # Multiple fragments or no fragments
        false
    end
  end

  defp check_identifier_validity(content, kind, scope) do
    charlist = String.to_charlist(content)

    case Toxic.Identifier.tokenize_identifier(charlist, 1, 1, scope, false) do
      {:identifier, ^charlist, _atom, [], _length, true, special} ->
        # Valid identifier, ASCII, no remaining input
        # For atoms, check that @ is not in special markers
        case kind do
          k when k in [:atom_safe, :atom_unsafe] ->
            if :at in special, do: false, else: {true, content}

          _ ->
            {true, content}
        end

      {:identifier, ^charlist, _atom, [], _length, false, _special} ->
        # Valid identifier but not ASCII - still valid for calls
        case kind do
          :quoted_identifier ->
            {true, content}

          _ ->
            false
        end

      _ ->
        false
    end
  end

  @doc false
  def maybe_warn_unnecessary_quote(kind, content, _delim, line, column, scope) do
    msg =
      case kind do
        k when k in [:atom_safe, :atom_unsafe] ->
          :io_lib.format(
            ~c"found quoted atom \"~ts\" but the quotes are not required. " ++
              ~c"Atoms made exclusively of ASCII letters, numbers, underscores, " ++
              ~c"beginning with a letter or underscore, and optionally ending with ! or ? " ++
              ~c"do not require quotes",
            [content]
          )

        k
        when k in [
               :kw_identifier_safe,
               :kw_identifier_unsafe,
               :kw_identifier_safe_end,
               :kw_identifier_unsafe_end
             ] ->
          :io_lib.format(
            ~c"found quoted keyword \"~ts\" but the quotes are not required. " ++
              ~c"Note that keywords are always atoms, even when quoted. " ++
              ~c"Similar to atoms, keywords made exclusively of ASCII " ++
              ~c"letters, numbers, and underscores and not beginning with a " ++
              ~c"number do not require quotes",
            [content]
          )

        :quoted_identifier ->
          :io_lib.format(
            ~c"found quoted call \"~ts\" but the quotes are not required. " ++
              ~c"Calls made exclusively of Unicode letters, numbers, and underscores " ++
              ~c"and not beginning with a number do not require quotes",
            [content]
          )
      end

    Toxic.Scope.prepend_warning(line, column, msg, scope)
  end

  # Phase 2: structural synthesis helpers
  defp synthesize_from_reason(%Toxic.Error{code: :terminator_mismatched_closer, details: %{expected_delimiter: expected}} = _err, state) do
    case synthesize_closing(expected, state) do
      {:ok, tok, new_scope} ->
        tok = maybe_tag_zero_len(tok, state)
        {:closer, [tok], new_scope}
      _ -> {:none, [], state.scope}
    end
  end

  defp synthesize_from_reason(%Toxic.Error{code: _code, token_display: token_display}, state) do
    # Unexpected closer (or similar) can be inferred from token chars
    flattened_chars = List.flatten(List.wrap(token_display))
    case closer_atom_from_chars(flattened_chars) do
      nil -> {:none, [], state.scope}
      closer ->
        case opening_for_closer(closer) do
          nil -> {:none, [], state.scope}
          opening ->
            # Insert synthetic opener and push to stack
            case synthesize_opening(opening, state) do
              {:ok, tok, new_scope} ->
                tok = maybe_tag_zero_len(tok, state)
                {:opener, [tok], new_scope}
              _ -> {:none, [], state.scope}
            end
        end
    end
  end

  defp synthesize_from_reason(_reason, state), do: {:none, [], state.scope}

  defp closer_atom_from_chars(~c")"), do: :")"
  defp closer_atom_from_chars(~c"]"), do: :"]"
  defp closer_atom_from_chars(~c"}"), do: :"}"
  defp closer_atom_from_chars([?>, ?>]), do: :">>"
  defp closer_atom_from_chars(~c"end"), do: :end
  defp closer_atom_from_chars(_), do: nil

  defp opening_for_closer(:")"), do: :"("
  defp opening_for_closer(:"]"), do: :"["
  defp opening_for_closer(:"}"), do: :"{"
  defp opening_for_closer(:">>"), do: :"<<"
  defp opening_for_closer(:end), do: nil
  defp opening_for_closer(_), do: nil

  defp synthesize_closing(closer, state) do
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    token = {closer, meta0}
    # Pop one if matches current opener; we will conservatively pop regardless
    scope(terminators: terms) = state.scope
    new_terms = case terms do
      [] -> []
      [_ | rest] -> rest
    end
    {:ok, token, scope(state.scope, terminators: new_terms)}
  end

  defp synthesize_opening(opening, state) do
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    token = {opening, meta0}
    scope(indentation: indent, terminators: terms) = state.scope
    new_terms = [{opening, meta0, indent} | terms]
    {:ok, token, scope(state.scope, terminators: new_terms)}
  end

  defp maybe_tag_zero_len({kind, {{sl, sc}, {_el, _ec}, extra}}, _state) do
    {kind, {{sl, sc}, {sl, sc}, extra}}
  end

  # Extract an actual closer atom from an error reason, if present
  defp actual_closer_from_reason(%Toxic.Error{} = err) do
    closer_atom_from_chars(List.flatten(List.wrap(err.token_display)))
  end

  defp actual_closer_from_reason(_), do: nil
end
