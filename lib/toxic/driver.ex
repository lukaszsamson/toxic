defmodule Toxic.Driver do
  defstruct [
    line: 1,
    column: 1,
    scope: nil,
    modes: [:normal],
    # New: prioritized deferral list for delayed emissions
    # Entries: {:emit_next, token, consume_len, after_action | nil}
    #  - consume_len: non-neg integer to consume from input and advance column
    #  - after_action: {:push_interp, kind, interpolation, delim} | nil
    deferrals: []
  ]

  require Record

  Record.defrecord(:scope, :toxic_tokenizer, Record.extract(:toxic_tokenizer, from: "src/toxic.hrl"))

  defguard is_vertical_space(char) when char in [?\n, ?\r]
  defguard is_horizontal_space(char) when char in [?\s, ?\t]
  defguard is_space(char) when is_vertical_space(char) or is_horizontal_space(char)
  defguard is_dual_op(char) when char in [?+, ?-]

  def new() do
    tokenizer = :toxic_config.identifier_tokenizer()
    %__MODULE__{
      scope: scope(identifier_tokenizer: tokenizer)
    }
  end

  def ensure_state_valid(%__MODULE__{modes: modes} = state) do
    case modes do
      [] -> raise ArgumentError, message: "modes is empty"
      [mode] when mode != :normal -> raise ArgumentError, message: "modes contains invalid top mode #{inspect(mode)}"
      list when is_list(list) ->
        if List.last(list) != :normal do
          raise ArgumentError, message: "modes contains invalid top mode #{inspect(modes)}"
        end
    end
    state
  end

  def next_with_validation(string, state) do
    result = next(string, state)
    state = result |> Tuple.to_list() |> List.last()
    ensure_state_valid(state)
    result
  end

  # Unified deferral handling: emit a queued token before consuming input
  def next(string, %__MODULE__{deferrals: [{:emit_next, pending_token, consume_len, next_action} | rest]} = state) when is_list(string) do
    {consumed, remaining} =
      if consume_len > 0 do
        Enum.split(string, consume_len)
      else
        {[], string}
      end

    new_column = state.column + length(consumed)

    new_state =
      case next_action do
        {:push_interp, kind, interpolation, delim} ->
          %{state | column: new_column, modes: [{:interp, kind, interpolation, delim} | state.modes], deferrals: rest}
        nil ->
          %{state | column: new_column, deferrals: rest}
      end

    {:ok, pending_token, remaining, new_state}
  end

  # Transform-next handling: decide identifier kind based on lookahead without consuming input
  def next(string, %__MODULE__{deferrals: [{:transform_next, :identifier, id_token} | rest]} = state) when is_list(string) do
    trimmed = trim_leading_spaces(string)

    new_token =
      cond do
        begins_with_do_keyword(trimmed) -> put_elem(id_token, 0, :do_identifier)
        List.starts_with?(trimmed, [?(]) -> put_elem(id_token, 0, :paren_identifier)
        List.starts_with?(trimmed, [?[ ]) -> put_elem(id_token, 0, :bracket_identifier)
        is_op_identifier_pattern(trimmed) -> put_elem(id_token, 0, :op_identifier)
        true -> id_token
      end

    {:ok, new_token, string, %{state | deferrals: rest}}
  end

  # Handle escaped newline at beginning: skip EOL emission and advance line/column
  def next([?\\, ?\n | tail], %__MODULE__{modes: [:normal | _]} = state) do
    stripped = trim_leading_spaces(tail)
    new_col = 1 + (length(tail) - length(stripped))
    next(stripped, %{state | line: state.line + 1, column: new_col})
  end
  def next([?\\, ?\r, ?\n | tail], %__MODULE__{modes: [:normal | _]} = state) do
    stripped = trim_leading_spaces(tail)
    new_col = 1 + (length(tail) - length(stripped))
    next(stripped, %{state | line: state.line + 1, column: new_col})
  end

  # Fold ",\n" into a single comma token with extra=1 (no EOL token)
  def next([?,, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:',', meta}
    new_state = %{state |
      line: state.line + 1,
      column: 1,
      modes: [:normal | modes_rest],
      deferrals: [{:pre_carry, [token]} | state.deferrals]
    }
    {:ok, token, tail, new_state}
  end
  def next([?,, ?\r, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:',', meta}
    new_state = %{state |
      line: state.line + 1,
      column: 1,
      modes: [:normal | modes_rest],
      deferrals: [{:pre_carry, [token]} | state.deferrals]
    }
    {:ok, token, tail, new_state}
  end

  # Fold ";\n" into a single semicolon token with extra=1 (no EOL token)
  def next([?;, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:';', meta}
    new_state = %{state |
      line: state.line + 1,
      column: 1,
      modes: [:normal | modes_rest],
      deferrals: [{:pre_carry, [token]} | state.deferrals]
    }
    {:ok, token, tail, new_state}
  end
  def next([?;, ?\r, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:';', meta}
    new_state = %{state |
      line: state.line + 1,
      column: 1,
      modes: [:normal | modes_rest],
      deferrals: [{:pre_carry, [token]} | state.deferrals]
    }
    {:ok, token, tail, new_state}
  end

  # Handle "\n=>" and "\r\n=>" by emitting only assoc_op with EOL count and no EOL token
  def next([?\n, ?=, ?> | tail], %__MODULE__{modes: [:normal | _]} = state) do
    meta = {{state.line + 1, 1}, {state.line + 1, 3}, 1}
    {:ok, {:assoc_op, meta, :"=>"}, tail, %{state | line: state.line + 1, column: 3}}
  end
  def next([?\r, ?\n, ?=, ?> | tail], %__MODULE__{modes: [:normal | _]} = state) do
    meta = {{state.line + 1, 1}, {state.line + 1, 3}, 1}
    {:ok, {:assoc_op, meta, :"=>"}, tail, %{state | line: state.line + 1, column: 3}}
  end


  # Emit pending deferral or coalesced EOL on EOF before falling back to generic eof
  def next([], %__MODULE__{deferrals: [{:emit_next, pending, _len, next_action} | rest]} = state) do
    new_state =
      case next_action do
        {:push_interp, kind, interpolation, delim} ->
          %{state | modes: [{:interp, kind, interpolation, delim} | state.modes], deferrals: rest}
        nil ->
          %{state | deferrals: rest}
      end
    {:ok, pending, [], new_state}
  end
  # Flush transform-next on EOF (no lookahead): emit as-is
  def next([], %__MODULE__{deferrals: [{:transform_next, :identifier, id_token} | rest]} = state) do
    {:ok, id_token, [], %{state | deferrals: rest}}
  end
  # Backward compatibility: if old modes are still present for EOF, handle them
  def next([], %__MODULE__{modes: [{:call_identifier_pending, pending} | modes_rest]} = state) do
    {:ok, pending, [], %{state | modes: modes_rest}}
  end
  def next([], %__MODULE__{modes: [{:eol_carry, eol_token} | modes_rest]} = state) do
    {:ok, eol_token, [], %{state | modes: modes_rest}}
  end

  # Awaiting 'in' after an EOL following 'not'
  def next(string, %__MODULE__{modes: [{:await_in_after_eol} | modes_rest]} = state) when is_list(string) do
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, []) do
      {:token, {:eol, _} = eol_token, rest, line, column, scope} ->
        trimmed = trim_leading_spaces(rest)
        if begins_with_in_keyword(trimmed) do
          next_state = %{state | line: line, column: column, scope: scope, modes: modes_rest, deferrals: [{:pre_carry, [eol_token]} | state.deferrals]}
          next(trimmed, next_state)
        else
          # Fallback: coalesce and emit EOL before next token
          next(rest, %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes_rest]})
        end
      other ->
        # Delegate to general handler by stripping the await marker
        case other do
          {:token, token, rest, line, column, scope} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:interp, interp_kind, interpolation, delim} | modes_rest]}}
          {:eof, line, column, scope} ->
            {:eof, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:error, reason, rest, _tokens, _warnings} ->
            {:error, reason, rest, %{state | modes: modes_rest}}
        end
    end
  end

  # Support emitting closers at BOL after an EOL token with count>0

  def next([], %__MODULE__{modes: [:normal | _]} = state) do
    {:eof, state}
  end
  def next([], %__MODULE__{} = state), do: {:eof, state}
  
  # Generic compatibility: convert a top carry_tokens into pre_carry for next call
  def next(string, %__MODULE__{modes: [{:carry_tokens, carry} | modes_rest]} = state) when is_list(string) do
    next(string, %{state | modes: modes_rest, deferrals: [{:pre_carry, carry} | state.deferrals]})
  end
  
  # Apply pre_carry (if present) with BOL indent adjustment
  def next(string, %__MODULE__{deferrals: [{:pre_carry, _} | _]} = state) when is_list(string) do
    {carry, rest_deferrals} = take_pre_carry(state.deferrals)
    case state.modes do
      [{:bol_indent, indent_col} | modes_rest] ->
        case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, carry) do
          {:token, token, rest, line, column, scope} ->
            adjusted = adjust_bol_operator(token, line, indent_col)
            {:ok, adjusted, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest, deferrals: rest_deferrals}}
          {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, deferrals: rest_deferrals, modes: [{:interp, interp_kind, interpolation, delim} | modes_rest]}}
          {:eof, line, column, scope} ->
            {:eof, %{state | line: line, column: column, scope: scope, modes: modes_rest, deferrals: rest_deferrals}}
          {:error, reason, rest, _tokens, _warnings} ->
            {:error, reason, rest, %{state | modes: modes_rest, deferrals: rest_deferrals}}
        end
      _ ->
        case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, carry) do
          {:token, token, rest, line, column, scope} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, deferrals: rest_deferrals}}
          {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, deferrals: rest_deferrals, modes: [{:interp, interp_kind, interpolation, delim} | state.modes]}}
          {:eof, line, column, scope} ->
            {:eof, %{state | line: line, column: column, scope: scope, deferrals: rest_deferrals}}
          {:error, reason, rest, _tokens, _warnings} ->
            {:error, reason, rest, %{state | deferrals: rest_deferrals}}
        end
    end
  end
  # Carried EOL with pending BOL indent: convert carry_tokens to pre_carry, then adjust operator
  def next(string, %__MODULE__{modes: [{:carry_tokens, carry}, {:bol_indent, indent_col} | modes_rest]} = state) when is_list(string) do
    next(string, %{state | modes: [{:bol_indent, indent_col} | modes_rest], deferrals: [{:pre_carry, carry} | state.deferrals]})
  end

  # (removed erroneous generic pre_carry handler)

  # If we have a recorded beginning-of-line indentation, adjust the first operator token accordingly
  def next(string, %__MODULE__{modes: [{:bol_indent, indent_col} | modes_rest]} = state) when is_list(string) do
    tokens = []
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, tokens) do
      {:token, token, rest, line, column, scope} ->
        adjusted = adjust_bol_operator(token, line, indent_col)
        {:ok, adjusted, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
      {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
        {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:interp, interp_kind, interpolation, delim} | modes_rest]}}
      {:eof, line, column, scope} ->
        {:eof, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
      {:error, reason, rest, _tokens, _warnings} ->
        {:error, reason, rest, %{state | modes: modes_rest}}
    end
  end

  # Emit a previously scanned token without consuming input (migrated to deferrals)
  def next(string, %__MODULE__{modes: [{:pending_token, pending} | modes_rest]} = state) when is_list(string) do
    new_state = %{state | modes: modes_rest, deferrals: [{:emit_next, pending, 0, nil} | state.deferrals]}
    next(string, new_state)
  end

  # (identifier_pending removed; all producers migrated to transform_next)

  # Coalesce consecutive EOLs and emit exactly one EOL before the next non-EOL token
  def next(string, %__MODULE__{modes: [{:eol_carry, eol_token} | modes_rest]} = state) when is_list(string) do
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, [eol_token]) do
      {:token, {:eol, _} = new_eol, rest, line, column, scope} ->
        # Keep coalescing EOLs
        next(rest, %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, new_eol} | modes_rest]})
      {:token, token, rest, line, column, scope} ->
        # Check if this is a token type that should fold EOLs or needs special handling
        case token do
          {:identifier, _, _} = id_token ->
            # Handle identifiers in eol_carry mode: resolve identifier first, then emit EOL
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              deferrals: [{:transform_next, :identifier, id_token} | state.deferrals]
            }
            next(rest, new_state)
          {:unary_op, _, :not} ->
            # Check if this 'not' will be merged with 'in' - if so, don't emit separate EOL
            trimmed = trim_leading_spaces(rest)
            if begins_with_in_keyword(trimmed) do
              # Double carry: carry both 'not' and EOL so tokenizer can merge with 'in'
              # 'not' must be first for tokenizer to find it, EOL second for previous_was_eol
              carry_state = %{state | line: line, column: column, scope: scope, modes: modes_rest, deferrals: [{:pre_carry, [token, eol_token]} | state.deferrals]}
              next(rest, carry_state)
            else
              # Standalone 'not', emit separate EOL and defer the unary
              new_state = %{state |
                line: line,
                column: column,
                scope: scope,
                modes: modes_rest,
                deferrals: [{:emit_next, token, 0, nil} | state.deferrals]
              }
              {:ok, eol_token, rest, new_state}
            end
          {:unary_op, _, _} ->
            # Other unary_op always emits separate EOL, never folds it
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              modes: modes_rest,
              deferrals: [{:emit_next, token, 0, nil} | state.deferrals]
            }
            {:ok, eol_token, rest, new_state}
          # Keyword operators that should fold EOLs
          {:when_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:and_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:or_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:in_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          # All other binary/ternary operators that should fold EOLs
          {:comp_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:arrow_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:match_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:in_match_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:type_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:dual_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:mult_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:power_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:concat_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:range_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:xor_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:pipe_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:stab_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:assoc_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:rel_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:ternary_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:capture_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:ellipsis_op, _, _} ->
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          _ ->
            # All other tokens (int, identifier, literals, etc.) should emit separate EOL
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              modes: modes_rest,
              deferrals: [{:emit_next, token, 0, nil} | state.deferrals]
            }
            {:ok, eol_token, rest, new_state}
        end
      {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
        # Emit EOL first, then defer interp start token and push interp after
        new_state = %{state |
          line: line,
          column: column,
          scope: scope,
          modes: modes_rest,
          deferrals: [{:emit_next, token, 0, {:push_interp, interp_kind, interpolation, delim}} | state.deferrals]
        }
        {:ok, eol_token, rest, new_state}
      {:eof, line, column, scope} ->
        # End of input: emit the coalesced EOL and finish
        {:ok, eol_token, [], %{state | line: line, column: column, scope: scope, modes: modes_rest}}
      {:error, reason, rest, _tokens, _warnings} ->
        {:error, reason, rest, %{state | modes: modes_rest}}
    end
  end

  # If we are inside an interpolation (i.e., :normal stacked over {:interp,...})
  # and the next char is '}', emit end_interpolation and return to interp mode.
  def next([?} | rest], %__MODULE__{modes: [:normal, {:interp, kind, interpolation, delim} | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, nil}
    new_state = %{state | column: state.column + 1, modes: [{:interp, kind, interpolation, delim} | modes_rest]}
    {:ok, {:end_interpolation, meta, kind}, rest, new_state}
  end

  def next(string, %__MODULE__{modes: [:normal | _] = modes} = state) when is_list(string) do
    # TODO: eliminate tokens
    # Handle escaped newlines at the driver level to avoid emitting EOL tokens
    case string do
      [?\\, ?\n | tail] ->
        # Move to next line, strip horizontal spaces, do not emit EOL
        stripped = trim_leading_spaces(tail)
        new_col = 1 + (length(tail) - length(stripped))
        next(stripped, %{state | line: state.line + 1, column: new_col, scope: state.scope})
      [?\\, ?\r, ?\n | tail] ->
        stripped = trim_leading_spaces(tail)
        new_col = 1 + (length(tail) - length(stripped))
        next(stripped, %{state | line: state.line + 1, column: new_col, scope: state.scope})
      # Fold immediate newline after comma/semicolon into their count
      [?,, ?\n | tail] ->
        meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
        {:ok, {:',', meta}, tail, %{state | line: state.line + 1, column: 1}}
      [?,, ?\r, ?\n | tail] ->
        meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
        {:ok, {:',', meta}, tail, %{state | line: state.line + 1, column: 1}}
      [?;, ?\n | tail] ->
        meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
        {:ok, {:';', meta}, tail, %{state | line: state.line + 1, column: 1}}
      [?;, ?\r, ?\n | tail] ->
        meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
        {:ok, {:';', meta}, tail, %{state | line: state.line + 1, column: 1}}
      _ -> :ok
    end

    tokens = []
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, tokens) do
      {:token, token, rest, line, column, scope} ->
        case token do
          {:., _} = dot_token ->
            # Carry the dot so the next token sees previous_was_dot/1
            new_state = %{state | line: line, column: column, scope: scope, modes: modes, deferrals: [{:pre_carry, [dot_token]} | state.deferrals]}
            {:ok, dot_token, rest, new_state}
          {:unary_op, _meta, :not} ->
            trimmed = trim_leading_spaces(rest)
            if begins_with_in_keyword(trimmed) do
            # Suppress standalone 'not'; carry it so tokenizer can merge into 'not in'
            spaces = length(rest) - length(trimmed)
            next_state = %{state | line: line, column: column + spaces, scope: scope, modes: modes, deferrals: [{:pre_carry, [token]} | state.deferrals]}
              next(trimmed, next_state)
            else
              {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:await_in_after_eol} | modes]}}
            end
          {:eol, _meta} = eol_token ->
            # Lookahead after EOL
            trimmed = trim_leading_spaces(rest)
            # Special case: previous was 'not' and next is keyword 'in' -> suppress EOL and carry it
            case modes do
              [{:await_in_after_eol} | modes_rest] ->
                if begins_with_in_keyword(trimmed) do
                     next_state = %{state | line: line, column: column, scope: scope, modes: modes_rest, deferrals: [{:pre_carry, [eol_token]} | state.deferrals]}
                  next(trimmed, next_state)
                else
                  :continue
                end
              _ -> :continue
            end
            |> case do
              :continue ->
                 case trimmed do
                  [?/ , ?/ | _] ->
                     # Suppress EOL for comment start
                     next_state = %{state | line: line, column: column, scope: scope, modes: modes, deferrals: [{:pre_carry, [eol_token]} | state.deferrals]}
                    next(trimmed, next_state)
                  [head | rest_after_op] when head in [?- , ?+ , ?@] ->
                    # Check if this is a standalone operator at beginning of line
                    # If operator is followed by space/tab + non-operator, it's likely standalone
                    case rest_after_op do
                      [?\s | [char | _]] when char not in [?-, ?+, ?@, ?\s, ?\t, ?\n, ?\r] ->
                        # Use eol_carry to let tokenizer decide
                        new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                        next(rest, new_state)
                      [?\t | [char | _]] when char not in [?-, ?+, ?@, ?\s, ?\t, ?\n, ?\r] ->
                        # Use eol_carry to let tokenizer decide
                        new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                        next(rest, new_state)
                      [char | _] when char not in [?-, ?+, ?@, ?\s, ?\t, ?\n, ?\r] ->
                        # This is a standalone unary operator like "\n-1" - emit separate EOL
                        {:ok, eol_token, rest, %{state | line: line, column: column, scope: scope}}
                      _ ->
                        # Continuation operator: carry EOL into next operator so tokenizer can fold it
                        next_state = %{state | line: line, column: column, scope: scope, modes: modes, deferrals: [{:pre_carry, [eol_token]} | state.deferrals]}
                        next(trimmed, next_state)
                    end
                  [46 | _] ->
                    # Suppress EOL before dot; do not emit EOL, continue scanning at dot
                    next(rest, %{state | line: line, column: column, scope: scope})
                  [93 | _] ->
                    # Use eol_carry to let tokenizer decide
                    new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                    next(rest, new_state)
                  [125 | _] ->
                    # Use eol_carry to let tokenizer decide
                    new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                    next(rest, new_state)
                  [41 | _] ->
                    # Use eol_carry to let tokenizer decide
                    new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                    next(rest, new_state)
                  [62, 62 | _] ->
                    # Use eol_carry to let tokenizer decide
                    new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                    next(rest, new_state)
                  _ ->
                    # Assoc op '=>' after multiple EOLs
                    {after_eols, extra_eols} = count_leading_eols(rest)
                    trimmed2 = trim_leading_spaces(after_eols)
                    case trimmed2 do
                      [61, 62 | _] ->
                        {:eol, {{sl, sc}, _endpos, _}} = eol_token
                        total = 1 + extra_eols
                        carry = {:eol, {{sl, sc}, {sl + total, 1}, total}}
                        spaces = length(after_eols) - length(trimmed2)
                        new_state = %{state | line: line + extra_eols, column: 1 + spaces, scope: scope, modes: modes, deferrals: [{:pre_carry, [carry]} | state.deferrals]}
                        next(trimmed2, new_state)
                      _ ->
                        # Coalesce EOLs, emit one EOL before next token
                        new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                        next(rest, new_state)
                    end
                end
              other -> other
            end
          {Kind, {{sl, sc}, {el, ec}, extra}} when Kind in [:",", :";"] ->
            # If a newline follows immediately, fold it into this token's extra instead of emitting EOL
            case rest do
              [?\n | tail] ->
                new_token = {Kind, {{sl, sc}, {el, ec}, (extra || 0) + 1}}
                new_state = %{state | line: line + 1, column: 1, scope: scope}
                {:ok, new_token, tail, new_state}
              [?\r, ?\n | tail] ->
                new_token = {Kind, {{sl, sc}, {el, ec}, (extra || 0) + 1}}
                new_state = %{state | line: line + 1, column: 1, scope: scope}
                {:ok, new_token, tail, new_state}
              _ ->
                {:ok, token, rest, %{state | line: line, column: column, scope: scope}}
            end
          {:identifier, _, _} = id_token ->
            # Don't emit immediately - defer classification via transform-next
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              deferrals: [{:transform_next, :identifier, id_token} | state.deferrals]
            }
            next(rest, new_state)
          _ ->
            case state.modes do
              [{:bol_indent, indent_col} | modes_rest2] ->
                {:ok, adjust_bol_operator(token, line, indent_col), rest, %{state | line: line, column: column, scope: scope, modes: modes_rest2}}
              _ ->
                {:ok, token, rest, %{state | line: line, column: column, scope: scope}}
            end
        end

      {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
        # Check if there are stored tokens to emit first (for quoted identifiers and call identifiers)
        case interpolation do
          [stored_token | _remaining_tokens] when interp_kind == :quoted_identifier ->
            # Emit stored token first, then use deferral to emit start then push interp
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              modes: modes,
              deferrals: [{:emit_next, token, 0, {:push_interp, interp_kind, [], delim}} | state.deferrals]
            }
            {:ok, stored_token, rest, new_state}
          [stored_token | _] when interp_kind == :call_identifier and delim == :op_kw ->
            # For "+: <space> <digit>", Elixir does not emit a separate dual_op before kw_identifier.
            # So we should emit only kw_identifier and drop the carried dual_op token for parity.
            {:ok, token, rest, %{state | line: line, column: column, scope: scope}}
          [stored_token | _remaining_tokens] when interp_kind == :call_identifier ->
            # Emit stored token (dot) first, then use deferral to emit the identifier
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              deferrals: [{:emit_next, token, 0, nil} | state.deferrals]
            }
            {:ok, stored_token, rest, new_state}
          _ ->
            # Normal case - no stored tokens, emit start token immediately
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:interp, interp_kind, interpolation, delim} | modes]}}
        end

      # Let the general clause handle '}' now that we added a fast path above

      {:eof, line, column, scope} ->
        {:eof, %{state | line: line, column: column, scope: scope}}

      {:error, reason, rest, _warnings, _tokens} ->
        # Handle tokenizer errors - return error from driver
        {:error, reason, rest, state}
    end
  end

  def next(string, %__MODULE__{modes: [{:interp_with_pending, kind, pending_token, delim} | modes_rest]} = state) do
    # Migrate to deferrals: emit pending token, then push interp context
    new_state = %{state | modes: modes_rest, deferrals: [{:emit_next, pending_token, 0, {:push_interp, kind, [], delim}} | state.deferrals]}
    # Immediately service deferral (no input consumption), to preserve behavior
    next(string, new_state)
  end

  def next(string, %__MODULE__{modes: [{:call_identifier_pending, pending_token} | modes_rest]} = state) do
    # Migrate to deferrals: emit pending identifier next without consuming input
    new_state = %{state | modes: modes_rest, deferrals: [{:emit_next, pending_token, 0, nil} | state.deferrals]}
    next(string, new_state)
  end

  def next(string, %__MODULE__{modes: [{:interp, kind, interpolation, delim} | modes_rest]} = state) do
    allow_interpol = case {kind, interpolation} do
      {:sigil, {:sigil_info, _sigil_atom, allow?, _delim}} -> allow?
      _ -> true
    end
    case :toxic_interpolation.extract_stream_event(state.line, state.column, state.scope, allow_interpol, string, delim) do
      {:fragment, meta, binary_part, rest, line, column, scope} ->
        case kind do
          :sigil ->
            part = unescape_sigil_fragment(binary_part, interpolation)
            {:ok, {:string_fragment, meta, part}, rest, %{state | line: line, column: column, scope: scope}}
          _ ->
            case :toxic_tokenizer.unescape_tokens([binary_part], line, column, scope) do
              {:ok, [unescaped]} ->
                {:ok, {:string_fragment, meta, unescaped}, rest, %{state | line: line, column: column, scope: scope}}
            end
        end

      {:begin_interpolation, meta, _kind, rest, line, column, scope} ->
        {:ok, {:begin_interpolation, meta, kind}, rest, %{state | line: line, column: column, scope: scope, modes: [:normal | state.modes]}}

      {:done, meta, _binary_part, indent, rest, line, column, scope} when kind in [:bin_heredoc, :list_heredoc] ->
        end_token_type = case kind do
          :list_heredoc -> :list_heredoc_end
          :bin_heredoc -> :bin_heredoc_end
        end
        {:ok, {end_token_type, meta, delim, indent}, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}


      {:done, meta, _binary_part, rest, line, column, scope} when kind == :quoted_identifier ->
        # Handle quoted identifier completion - look ahead to determine correct end token type
        trimmed = trim_leading_spaces(rest)
        {end_token_type, final_rest, final_column, custom_meta} =
          cond do
            match?([?( | _], rest) ->
              {:quoted_paren_identifier_end, rest, column, nil}
            match?([?[ | _], rest) ->
              {:quoted_bracket_identifier_end, rest, column, nil}
            begins_with_do_keyword(trimmed) ->
              # Don't consume the "do" keyword - let normal tokenizer handle it
              # linear_to_legacy will only generate the do_identifier token
              {:quoted_do_identifier_end, rest, column, nil}
            match?([sign | _] when sign in [?+, ?-], trimmed) ->
              case trimmed do
                # TODO: this may be invalid
                [sign, next | _] when next not in [?\n, ?\r, ?\t, ?\s, ?/, ?>, ?:] and next != sign ->
                  {:quoted_op_identifier_end, rest, column, nil}
                _ ->
                  {:quoted_identifier_end, rest, column, nil}
              end
            true ->
              {:quoted_identifier_end, rest, column, nil}
          end
        # Use custom metadata for special cases like quoted_do_identifier_end
        token_meta = custom_meta || meta
        end_token = {end_token_type, token_meta, delim}

        {:ok, end_token, final_rest, %{state | line: line, column: final_column, scope: scope, modes: modes_rest}}

      # Sigil heredoc completion (with indentation)
      {:done, meta, _binary_part, indent, rest, line, column, scope} when kind == :sigil ->
        {sigil_atom, start_delim} = sigil_from_interp(interpolation)
        end_token = {:sigil_end, meta, sigil_atom, start_delim, indent}
        case collect_sigil_modifiers(rest, line, column) do
          {:none} ->
            {:ok, end_token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:mods, mods_token, rest_after, new_column} ->
            # Emit end token first, schedule modifiers via deferral (consume characters)
            consume_len = new_column - column
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              modes: modes_rest,
              deferrals: [{:emit_next, mods_token, consume_len, nil} | state.deferrals]
            }
            {:ok, end_token, rest, new_state}
        end

      # Sigil completion (no indentation)
      {:done, meta, _binary_part, rest, line, column, scope} when kind == :sigil ->
        {sigil_atom, start_delim} = sigil_from_interp(interpolation)
        end_token = {:sigil_end, meta, sigil_atom, start_delim, nil}
        case collect_sigil_modifiers(rest, line, column) do
          {:none} ->
            {:ok, end_token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:mods, mods_token, rest_after, new_column} ->
            consume_len = new_column - column
            new_state = %{state |
              line: line,
              column: column,
              scope: scope,
              modes: modes_rest,
              deferrals: [{:emit_next, mods_token, consume_len, nil} | state.deferrals]
            }
            {:ok, end_token, rest, new_state}
        end

      {:done, meta, _binary_part, rest, line, column, scope} ->
        case rest do
          [?:, ws | tail] when is_space(ws) ->
            {{sl, sc}, {el, ec}, extra} = meta
            adj_meta = {{sl, sc}, {el, ec + 1}, extra}

            end_token_type = case scope do
              scope(existing_atoms_only: true) -> :kw_identifier_safe_end
              _ -> :kw_identifier_unsafe_end
            end
            {:ok, {end_token_type, adj_meta, delim}, [ws | tail], %{state | line: line, column: column + 1, scope: scope, modes: modes_rest}};
          _ ->
            end_token_type = case kind do
              :charlist -> :list_string_end
              :atom_safe -> :atom_safe_end
              :atom_unsafe -> :atom_unsafe_end
              _ -> :bin_string_end
            end
            {:ok, {end_token_type, meta, delim}, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
        end

      {:error, reason} ->
        # Handle errors from interpolation extraction
        {:error, reason, string, %{state | modes: modes_rest}}
    end
  end

  def next(string, %__MODULE__{modes: [{:sigil_mods_pending, pending_token, len} | modes_rest]} = state) do
    # Migrate to deferrals: emit pending modifiers after consuming len characters
    new_state = %{state | modes: modes_rest, deferrals: [{:emit_next, pending_token, len, nil} | state.deferrals]}
    next(string, new_state)
  end

  defp sigil_from_interp({:sigil_info, sigil_atom, _interpol?, start_delim}), do: {sigil_atom, start_delim}
  defp sigil_from_interp(_), do: {:sigil, nil}

  defp unescape_sigil_fragment(binary_part, {:sigil_info, _sigil_atom, _allow?, start_delim}) when is_binary(start_delim) and byte_size(start_delim) == 1 do
    open = :binary.first(start_delim)
    close = case open do
      ?( -> ?) ; ?[ -> ?] ; ?{ -> ?} ; ?< -> ?> ; other -> other
    end
    :binary.replace(binary_part, <<?\\, close>>, <<close>>, [:global])
  end
  defp unescape_sigil_fragment(binary_part, _), do: binary_part

  # Collect and clear all pre_carry deferrals into a single carry list
  defp take_pre_carry(deferrals) do
    {pre_list, rest} = Enum.split_with(deferrals, fn d -> match?({:pre_carry, _}, d) end)
    carry = pre_list |> Enum.flat_map(fn {:pre_carry, toks} -> toks end)
    {Enum.reverse(carry), rest}
  end

  defp collect_sigil_modifiers(rest, line, column) do
    {mods, rest_after} = do_take_mods(rest, [])
    case mods do
      [] -> {:none}
      _ ->
        len = length(mods)
        meta = {{line, column}, {line, column + len}, nil}
        {:mods, {:sigil_modifiers, meta, List.to_charlist(mods)}, rest_after, column + len}
    end
  end

  defp do_take_mods([h | t], acc) when h in ?a..?z or h in ?A..?Z or h in ?0..?9 do
    do_take_mods(t, [h | acc])
  end
  defp do_take_mods(rest, acc), do: {Enum.reverse(acc), rest}

  defp trim_leading_spaces([c | rest]) when c in [?\t, ?\s], do: trim_leading_spaces(rest)
  defp trim_leading_spaces(list), do: list

  defp count_leading_spaces([c | rest]) when c in [?\t, ?\s], do: 1 + count_leading_spaces(rest)
  defp count_leading_spaces(_), do: 0

  # Count leading EOL sequences (LF or CRLF)
  defp count_leading_eols([?\r, ?\n | rest]) do
    {after_rest, n} = count_leading_eols(rest)
    {after_rest, n + 1}
  end
  defp count_leading_eols([?\n | rest]) do
    {after_rest, n} = count_leading_eols(rest)
    {after_rest, n + 1}
  end
  defp count_leading_eols(rest), do: {rest, 0}

  # Detect if the upcoming input starts with the standalone keyword "in"
  defp begins_with_in_keyword([?i, ?n, next | _]) do
    not is_identifier_char(next)
  end
  defp begins_with_in_keyword([?i, ?n]), do: true
  defp begins_with_in_keyword(_), do: false

  # Detect if the upcoming input starts with the standalone keyword "do"
  defp begins_with_do_keyword([?d, ?o, next | _]) do
    not is_identifier_char(next)
  end
  defp begins_with_do_keyword([?d, ?o]), do: true
  defp begins_with_do_keyword(_), do: false

  # Check if string matches op_identifier pattern: dual_op followed by non-space
  # Based on Erlang logic from handle_space_sensitive_tokens:
  # 1. Special case: [Sign, $:, Space] -> don't convert (line 1686)
  # 2. General case: ?dual_op(Sign), not(?is_space(NotMarker)), NotMarker =/= Sign, NotMarker =/= $/, NotMarker =/= $>
  defp is_op_identifier_pattern([sign, ?:, space | _]) when is_dual_op(sign) and is_space(space) do
    # Special case: dual_op followed by colon and space -> don't convert to op_identifier
    false
  end
  defp is_op_identifier_pattern([sign, not_marker | _]) when is_dual_op(sign) and not is_space(not_marker) do
    # General case: dual_op followed by non-space (excluding special characters)
    not_marker != sign and not_marker != ?/ and not_marker != ?>
  end
  defp is_op_identifier_pattern(_), do: false

  # TODO: GTFO whith this hack
  defp is_identifier_char(char) when char in ?a..?z, do: true
  defp is_identifier_char(char) when char in ?A..?Z, do: true
  defp is_identifier_char(char) when char in ?0..?9, do: true
  defp is_identifier_char(?_), do: true
  defp is_identifier_char(_), do: false

  # Adjust operator column at beginning of line after EOL indentation
  defp adjust_bol_operator({kind, {{sl, sc}, {el, ec}, extra}, value} = tok, line, indent_col)
       when kind in [:dual_op, :unary_op, :at_op] do
    if sl == line and sc < indent_col do
      len = ec - sc
      {kind, {{line, indent_col}, {line, indent_col + len}, extra}, value}
    else
      tok
    end
  end
  defp adjust_bol_operator(tok, _line, _indent_col), do: tok
end
