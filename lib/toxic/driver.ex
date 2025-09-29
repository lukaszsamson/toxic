defmodule Toxic.Driver do
  import Toxic.Scope
  import Toxic.Token
  import Toxic.CharacterClassifier

  defstruct line: 1,
            column: 1,
            scope: nil,
            contexts: [:normal],
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

    %__MODULE__{
      line: line,
      column: column,
      scope:
        scope(
          identifier_tokenizer: String.Tokenizer,
          elixir_compatibility: elixir_compatibility,
          preserve_comments: preserve_comments,
          existing_atoms_only: existing_atoms_only
        )
    }
  end

  # TODO: remove? no longer needed
  def next_with_validation(string, state) do
    result = next(string, state)
    state = result |> Tuple.to_list() |> List.last()
    ensure_state_valid(state)
    result
  end

  defp ensure_state_valid(%__MODULE__{contexts: contexts} = state) do
    case contexts do
      [] ->
        raise ArgumentError, message: "contexts is empty"

      [mode] when mode != :normal ->
        raise ArgumentError, message: "contexts contains invalid top mode #{inspect(mode)}"

      list when is_list(list) ->
        if List.last(list) != :normal do
          raise ArgumentError, message: "contexts contains invalid top entry #{inspect(contexts)}"
        end
    end

    state
  end

  def next(rest, %__MODULE__{output: [h | t]} = state) do
    return_token(h, rest, %{state | output: t})
  end

  def next([], %__MODULE__{deferrals: []} = state) do
    case pending_error(state) do
      nil ->
        {:eof, state}

      {:missing_interpolation, interp_context} ->
        {:error, missing_interpolation_reason(interp_context, state), [], state}

      {:missing_context, interp_context} ->
        {:error, missing_terminator_reason(interp_context, state), [], state}

      {:missing_scope, entry} ->
        {:error, missing_scope_terminator_reason(entry, state), [], state}
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
    {:error, mismatched_delimiter_reason(entry, :"}", state), rest, state}
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

  # TODO: no coverage, not possible?
  # def next(
  #       [?} | rest],
  #       %__MODULE__{
  #         contexts: [
  #           :normal,
  #           {:interp, kind, interpolation, delim, parent_terminators, start_info} | contexts_rest
  #         ],
  #         deferrals: deferrals,
  #         scope: scope(terminators: [{start, _meta, _indent} | _])
  #       } =
  #         state
  #     )
  #     when start != :"{" do
  #   meta = {{state.line, state.column}, {state.line, state.column + 1}, nil}

  #   new_state = %{
  #     state
  #     | column: state.column + 1,
  #       contexts: [
  #         {:interp, kind, interpolation, delim, parent_terminators, start_info} | contexts_rest
  #       ],
  #       output: Enum.reverse([{:end_interpolation, meta, kind} | deferrals]),
  #       deferrals: []
  #   }

  #   next(rest, new_state)
  # end

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
        {:error, reason, string, state}

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
        {:error, reason, string, state}

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

      # Sigil completion (no indentation)
      {:done, meta, _binary_part, rest, line, column, scope} when kind == :sigil ->
        # {sigil_atom, start_delim} = sigil_from_interp(interpolation)
        end_token = {:sigil_end, meta, delim, nil}

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

      {:done, meta, _binary_part, indent, rest, line, column, scope} when kind == :sigil ->
        # {sigil_atom, start_delim} = sigil_from_interp(interpolation)
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

      # TODO: refactor - add indent in other clauses
      {:done, meta, _binary_part, indent, rest, line, column, scope}
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

      {:done, meta, _binary_part, rest, line, column, scope} when kind == :quoted_identifier ->
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

      {:done, meta, _binary_part, rest, line, column, scope} ->
        # TODO: why binary_part?
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
                    # For atoms, start_info.column already points to the : position
                    __MODULE__.maybe_warn_unnecessary_quote(
                      kind,
                      content,
                      delim,
                      start_info.line,
                      start_info.column,
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

      {:begin_interpolation, meta, _kind, rest, line, column, scope} ->
        if kind == :quoted_identifier do
          {:error,
           interpolation_in_quoted_identifier_reason(start_info.line, start_info.column, delim),
           rest, state}
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

  defp compute_start_info(start_token, _delimiter, _line, _column) do
    {{meta_start_line, meta_start_column}, {_meta_end_line, _meta_end_column}, _extra} =
      elem(start_token, 1)

    # Use the start column from the token's meta, which is the opening delimiter position
    %{line: meta_start_line, column: meta_start_column, token: start_token}
  end

  defp pending_error(%__MODULE__{contexts: contexts, scope: scope} = _state) do
    cond do
      interp = find_missing_interpolation(contexts) ->
        {:missing_interpolation, interp}

      context = find_missing_context(contexts) ->
        {:missing_context, context}

      entry = find_missing_scope_terminator(scope) ->
        {:missing_scope, entry}

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

    meta = [
      opening_delimiter: opening_atom,
      expected_delimiter: opening_atom,
      line: start_line,
      column: start_column,
      end_line: resolved_end_line,
      end_column: resolved_end_column
    ]

    message = :io_lib.format(~c"missing terminator: ~ts", [delim_chars])
    suffix = context_suffix(kind, delim, start_info)

    {meta, [message, suffix], []}
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

    meta = [
      opening_delimiter: opening_atom,
      expected_delimiter: opening_atom,
      line: start_line,
      column: start_column,
      end_line: resolved_end_line,
      end_column: resolved_end_column
    ]

    message = :io_lib.format(~c"missing interpolation terminator: \"~ts\"", [[?}]])
    suffix = context_suffix(kind, delim, start_info)

    {meta, [message, suffix], []}
  end

  defp missing_scope_terminator_reason(
         {start, meta, _indentation} = entry,
         %__MODULE__{line: end_line, column: end_column, scope: scope} = _state
       ) do
    closing = closing_for(start)
    closing_chars = terminator_chars(closing)
    message = :io_lib.format(~c"missing terminator: ~ts", [closing_chars])
    hint = missing_scope_hint(entry, closing, scope)

    {{start_line, start_column}, _end_pos, _extra} = meta

    meta_list = [
      opening_delimiter: start,
      expected_delimiter: closing,
      line: start_line,
      column: start_column,
      end_line: end_line,
      end_column: end_column
    ]

    {meta_list, [message, hint], []}
  end

  defp mismatched_delimiter_reason({start, meta, _indent}, closing, %__MODULE__{
         line: end_line,
         column: end_column
       }) do
    expected = closing_for(start)
    closing_chars = terminator_chars(closing)

    {{start_line, start_column}, _end_pos, _extra} = meta

    meta_list = [
      line: start_line,
      column: start_column,
      end_line: end_line,
      end_column: end_column,
      error_type: :mismatched_delimiter,
      opening_delimiter: start,
      closing_delimiter: closing,
      expected_delimiter: expected
    ]

    {meta_list, ~c"unexpected token: ", closing_chars}
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
    message =
      ~c"interpolation is not allowed when calling function/macro. Found interpolation in a call starting with: "

    {[line: start_line, column: start_column], message, delimiter_charlist(delim)}
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
  # TODO: no coverage, not possible?
  # defp missing_scope_hint({_start, _meta, _indent}, _closing, scope(mismatch_hints: _)), do: []

  # Helper to return a token and update recent_token in state
  defp return_token(token, rest, state) do
    {:ok, token, rest, %{state | recent_token: token}}
  end

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

  @doc """
  Suggest a missing closing terminator based on the current stack.

  Returns the closer atom (e.g., :")", :"]", :"}", :">>", :end) or nil if none.
  """
  # TODO: remove? not used
  @spec peek_missing_terminator(t()) :: atom() | nil
  def peek_missing_terminator(%__MODULE__{} = driver) do
    case current_terminators(driver) do
      [{start, _meta, _indent} | _] -> closing_for(start)
      [] -> nil
    end
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
end
