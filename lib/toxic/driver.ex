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
            list(:normal | {:interp, interp_kind(), boolean(), interp_delim(), terminators()}),
          deferrals: list(),
          output: list(),
          recent_token: any()
        }

  def new(opts \\ []) do
    elixir_compatibility = Keyword.get(opts, :elixir_compatibility, false)
    preserve_comments = Keyword.get(opts, :preserve_comments, false)
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)

    %__MODULE__{
      line: line,
      column: column,
      scope:
        scope(
          identifier_tokenizer: String.Tokenizer,
          elixir_compatibility: elixir_compatibility,
          preserve_comments: preserve_comments
        )
    }
  end

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
    {:eof, state}
  end

  def next([], %__MODULE__{deferrals: [_h | _t] = deferrals} = state) do
    next([], %{state | deferrals: [], output: Enum.reverse(deferrals)})
  end

  def next(
        [?} | rest],
        %__MODULE__{
          contexts: [
            :normal,
            {:interp, kind, interpolation, delim, parent_terminators} | contexts_rest
          ],
          deferrals: deferrals,
          scope: scope(terminators: terminators)
        } =
          state
      )
      when terminators == [] or elem(hd(terminators), 0) != :"{" do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, nil}

    new_state = %{
      state
      | column: state.column + 1,
        contexts: [{:interp, kind, interpolation, delim, parent_terminators} | contexts_rest],
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
        {:error, reason, string, state}

      {rest, state} ->
        next(rest, state)
    end
  end

  def next(
        string,
        %__MODULE__{
          contexts:
            [{:interp, kind, interpolation_allowed?, delim, parent_terminators} | contexts_rest] =
              contexts
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

        return_token(
          {:string_fragment, meta(start_line, start_column, line, end_column, extra),
           binary_part},
          rest,
          %{
            state
            | line: line,
              column: column,
              scope: scope
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

        return_token({end_token_type, meta, delim, indent}, rest, %{
          state
          | line: line,
            column: column,
            scope: scope(scope, terminators: parent_terminators),
            contexts: contexts_rest
        })

      {:done, meta, _binary_part, rest, line, column, scope} when kind == :quoted_identifier ->
        end_token_type =
          case rest do
            [?( | _] -> :quoted_paren_identifier_end
            [?[ | _] -> :quoted_bracket_identifier_end
            _ -> :quoted_identifier_end
          end

        if end_token_type == :quoted_identifier_end do
          next(rest, %{
            state
            | line: line,
              column: column,
              scope: scope(scope, terminators: parent_terminators),
              contexts: contexts_rest,
              deferrals: [{end_token_type, meta, delim}]
          })
        else
          return_token({end_token_type, meta, delim}, rest, %{
            state
            | line: line,
              column: column,
              scope: scope(scope, terminators: parent_terminators),
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
                  # TODO: no test coverage
                  :kw_identifier_safe_end

                _ ->
                  :kw_identifier_unsafe_end
              end

            {:ok, {end_token_type, adj_meta, delim}, [ws | tail],
             %{
               state
               | line: line,
                 column: column + 1,
                 scope: scope(scope, terminators: parent_terminators),
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

            return_token({end_token_type, meta, delim}, rest, %{
              state
              | line: line,
                column: column,
                scope: scope(scope, terminators: parent_terminators),
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
        contexts = [
          {:interp, interp_kind, interpolation_allowed?, delimiter, terminators} | contexts
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

        {{:interp, _kind, _allowed?, delim, parent_terms}, _index} ->
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
end
