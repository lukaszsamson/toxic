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

  def new() do
    tokenizer = :toxic_config.identifier_tokenizer()

    %__MODULE__{
      scope: scope(identifier_tokenizer: tokenizer)
    }
  end

  def next_with_validation(string, state) do
    result = next(string, state) |> dbg
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
    {:eof, state}
  end

  def next([], %__MODULE__{deferrals: [h | t]} = state) do
    return_token(h, [], %{state | deferrals: t})
  end

  def next(
        [?} | rest],
        %__MODULE__{contexts: [:normal, {:interp, kind, interpolation, delim} | contexts_rest]} =
          state
      ) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, nil}

    new_state = %{
      state
      | column: state.column + 1,
        contexts: [{:interp, kind, interpolation, delim} | contexts_rest]
    }

    return_token({:end_interpolation, meta, kind}, rest, new_state)
  end

  def next(string, %__MODULE__{contexts: [:normal | _] = contexts} = state) do
    carry_with_recent = state.deferrals

    result =
      Toxic.Tokenizer.tokenize_single(
        string,
        state.line,
        state.column,
        state.scope,
        carry_with_recent
      )
      |> dbg

    handle_tokenize_result(state, result)
  end

  def next(
        string,
        %__MODULE__{
          contexts: [{:interp, kind, interpolation_allowed?, delim} | contexts_rest] = contexts
        } =
          state
      ) do
    case :toxic_interpolation.extract_stream_event(
           state.line,
           state.column,
           state.scope,
           interpolation_allowed?,
           string,
           delim |> dbg
         )
         |> dbg do
      {:fragment, meta, binary_part, rest, line, column, scope} ->
        case kind do
          :sigil ->
            return_token({:string_fragment, meta, binary_part}, rest, %{
              state
              | line: line,
                column: column,
                scope: scope
            })

          _ ->
            # TODO: handle unescape error
            case :toxic_tokenizer.unescape_tokens([binary_part], line, column, scope) do
              {:ok, [unescaped]} ->
                return_token({:string_fragment, meta, unescaped}, rest, %{
                  state
                  | line: line,
                    column: column,
                    scope: scope
                })
            end
        end

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
            scope: scope,
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
            scope: scope,
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

        return_token({end_token_type, meta, delim, indent}, rest, %{
          state
          | line: line,
            column: column,
            scope: scope,
            contexts: contexts_rest
        })

      {:done, meta, _binary_part, rest, line, column, scope} ->
        # TODO: why binary_part?
        case rest do
          [?:, ws | tail] when is_space(ws) ->
            {{sl, sc}, {el, ec}, extra} = meta
            adj_meta = {{sl, sc}, {el, ec + 1}, extra}

            end_token_type =
              case scope do
                scope(existing_atoms_only: true) -> :kw_identifier_safe_end
                _ -> :kw_identifier_unsafe_end
              end

            {:ok, {end_token_type, adj_meta, delim}, [ws | tail],
             %{state | line: line, column: column + 1, scope: scope, contexts: contexts_rest}}

          _ ->
            end_token_type =
              case kind do
                :charlist -> :list_string_end
                :atom_safe -> :atom_safe_end
                :atom_unsafe -> :atom_unsafe_end
                _ -> :bin_string_end
              end

            dbg(rest)
            dbg({line, column})

            return_token({end_token_type, meta, delim}, rest, %{
              state
              | line: line,
                column: column,
                scope: scope,
                contexts: contexts_rest
            })
        end

      {:begin_interpolation, meta, _kind, rest, line, column, scope} ->
        updated = %{
          state
          | line: line,
            column: column,
            scope: scope,
            contexts: [:normal | contexts]
        }

        return_token({:begin_interpolation, meta, kind}, rest, updated)
    end
  end

  defp handle_tokenize_result(
         state = %__MODULE__{contexts: contexts, deferrals: deferrals, output: output},
         result
       ) do
    case result do
      :eof ->
        next([], state)

      # {:eof, state}

      {nil, rest, line, column, scope} ->
        next(rest, %{state | line: line, column: column, scope: scope})

      {events, rest, line, column, scope} when is_list(events) ->
        # TODO: figure out
        next(rest, %{state | line: line, column: column, scope: scope})

      {:reset_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, _extra)} | t] = deferrals

        next(rest, %{
          state
          | line: line,
            column: column,
            scope: scope,
            deferrals: [{kind, meta(start_line, start_column, line, column, 0)} | t]
        })

      {:increase_eol, rest, line, column, scope} ->
        [{kind, meta(start_line, start_column, _end_line, _end_column, extra)} | t] = deferrals

        next(rest, %{
          state
          | line: line,
            column: column,
            scope: scope,
            deferrals: [{kind, meta(start_line, start_column, line, column, extra + 1)} | t]
        })

      {{:token, {eol, _meta} = token}, rest, line, column, scope}
      when eol in [:eol, :";", :","] ->
        IO.puts("deferring #{inspect(token)}")

        next(rest, %{
          state
          | line: line,
            column: column,
            scope: scope,
            output: Enum.reverse(deferrals),
            deferrals: [token]
        })

      {{:token, token}, rest, line, column, scope} ->
        case deferrals do
          [] ->
            return_token(token, rest, %{state | line: line, column: column, scope: scope})

          other ->
            [h | t] = Enum.reverse(other)

            return_token(h, rest, %{
              state
              | line: line,
                column: column,
                scope: scope,
                deferrals: [],
                output: t ++ [token]
            })
        end

      {{:dual_op_identifier, token}, rest, line, column, scope} ->
        # TODO: implement identifier change to op_identifier
        return_token(token, rest, %{state | line: line, column: column, scope: scope})

      {{:token_with_eol, token}, rest, line, column, scope} ->
        carry_with_recent =
          case {token, deferrals} do
            {{:unary_op, _, _} = left, tokens} -> [left | tokens]
            {left, [{:eol, _} | tokens]} -> [left | tokens]
            {left, tokens} -> [left | tokens]
          end

        next(rest, %{
          state
          | line: line,
            column: column,
            scope: scope,
            output: Enum.reverse(carry_with_recent),
            deferrals: []
        })

      {{:switch_to_interp, start_token, interp_kind, interpolation_allowed?, delimiter}, rest,
       line, column, scope} ->
        contexts = [{:interp, interp_kind, interpolation_allowed?, delimiter} | contexts]

        next(rest, %{
          state
          | line: line,
            column: column,
            scope: scope,
            output: Enum.reverse([start_token | deferrals]),
            deferrals: [],
            contexts: contexts
        })
    end
  end

  # Helper to return a token and update recent_token in state
  defp return_token(token, rest, state) do
    {:ok, token, rest, %{state | recent_token: token}}
  end
end
