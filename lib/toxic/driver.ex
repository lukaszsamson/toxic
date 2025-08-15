defmodule Toxic.Driver do
  defstruct [
    line: 1,
    column: 1,
    scope: nil,
    modes: [:normal]
  ]

  require Record

  Record.defrecord(:scope, :toxic_tokenizer, Record.extract(:toxic_tokenizer, from: "src/toxic.hrl"))

  defguard is_vertical_space(char) when char in [?\n, ?\r]
  defguard is_horizontal_space(char) when char in [?\s, ?\t]
  defguard is_space(char) when is_vertical_space(char) or is_horizontal_space(char)

  def new() do
    tokenizer = :toxic_config.identifier_tokenizer()
    %__MODULE__{
      scope: scope(identifier_tokenizer: tokenizer)
    }
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
    new_state = %{state | line: state.line + 1, column: 1, modes: [{:carry_tokens, [token]} | modes_rest]}
    {:ok, token, tail, new_state}
  end
  def next([?,, ?\r, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:',', meta}
    new_state = %{state | line: state.line + 1, column: 1, modes: [{:carry_tokens, [token]} | modes_rest]}
    {:ok, token, tail, new_state}
  end

  # Fold ";\n" into a single semicolon token with extra=1 (no EOL token)
  def next([?;, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:';', meta}
    new_state = %{state | line: state.line + 1, column: 1, modes: [{:carry_tokens, [token]} | modes_rest]}
    {:ok, token, tail, new_state}
  end
  def next([?;, ?\r, ?\n | tail], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    meta = {{state.line, state.column}, {state.line, state.column + 1}, 1}
    token = {:';', meta}
    new_state = %{state | line: state.line + 1, column: 1, modes: [{:carry_tokens, [token]} | modes_rest]}
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

  
  # Emit pending token or coalesced EOL on EOF before falling back to generic eof
  def next([], %__MODULE__{modes: [{:call_identifier_pending, pending} | modes_rest]} = state) do
    {:ok, pending, [], %{state | modes: modes_rest}}
  end
  def next([], %__MODULE__{modes: [{:pending_token, pending} | modes_rest]} = state) do
    {:ok, pending, [], %{state | modes: modes_rest}}
  end
  def next([], %__MODULE__{modes: [{:eol_carry, eol_token} | modes_rest]} = state) do
    {:ok, eol_token, [], %{state | modes: modes_rest}}
  end

  # Support emitting closers at BOL after an EOL token with count>0
  def next([], %__MODULE__{modes: [:normal | _]} = state) do
    {:eof, state}
  end
  def next([], %__MODULE__{} = state), do: {:eof, state}
  # Carried EOL with pending BOL indent: adjust the first operator token to indentation column
  def next(string, %__MODULE__{modes: [{:carry_tokens, carry}, {:bol_indent, indent_col} | modes_rest]} = state) when is_list(string) do
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, carry) do
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

  def next(string, %__MODULE__{modes: [{:carry_tokens, carry} | modes_rest]} = state) when is_list(string) do
    # Pass along carried previous tokens (e.g., EOL) so tokenizer can attach EOL to next token and optionally drop it
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, carry) do
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

  # Emit a previously scanned token without consuming input (input already advanced earlier)
  def next(string, %__MODULE__{modes: [{:pending_token, pending} | modes_rest]} = state) when is_list(string) do
    {:ok, pending, string, %{state | modes: modes_rest}}
  end

  # Coalesce consecutive EOLs and emit exactly one EOL before the next non-EOL token
  def next(string, %__MODULE__{modes: [{:eol_carry, eol_token} | modes_rest]} = state) when is_list(string) do
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, [eol_token]) do
      {:token, {:eol, _} = new_eol, rest, line, column, scope} ->
        # Keep coalescing EOLs
        next(rest, %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, new_eol} | modes_rest]})
      {:token, token, rest, line, column, scope} ->
        # Emit the final EOL first, queue the non-EOL token for next call
        new_state = %{state | line: line, column: column, scope: scope, modes: [{:pending_token, token} | modes_rest]}
        {:ok, eol_token, rest, new_state}
      {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
        # Emit EOL first, then handle interp start as a pending token
        new_modes = [{:pending_token, token}, {:interp, interp_kind, interpolation, delim} | modes_rest]
        {:ok, eol_token, rest, %{state | line: line, column: column, scope: scope, modes: new_modes}}
      {:eof, line, column, scope} ->
        # End of input: emit the coalesced EOL and finish
        {:ok, eol_token, [], %{state | line: line, column: column, scope: scope, modes: modes_rest}}
      {:error, reason, rest, _tokens, _warnings} ->
        {:error, reason, rest, %{state | modes: modes_rest}}
    end
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
          {:eol, _meta} = eol_token ->
            # Lookahead after EOL: if next non-space starts with '//', suppress EOL emission
            trimmed = trim_leading_spaces(rest)
            case trimmed do
              [?/ , ?/ | _] ->
                # Suppress EOL; carry it into next scan and immediately fetch next token
                next_state = %{state | line: line, column: column, scope: scope, modes: [{:carry_tokens, [eol_token]} | modes]}
                next(trimmed, next_state)
              [head | _] when head in [?- , ?+ , ?@] ->
                # Record the indentation column for the next operator; do not carry EOL into operator
                indent_col = column + count_leading_spaces(rest)
                new_modes = [{:bol_indent, indent_col} | modes]
                new_state = %{state | line: line, column: column, scope: scope, modes: new_modes}
                {:ok, eol_token, rest, new_state}
              [93 | _] ->
                # Closer: emit EOL separately and carry it into closer
                new_state = %{state | line: line, column: column, scope: scope, modes: [{:carry_tokens, [eol_token]} | modes]}
                {:ok, eol_token, rest, new_state}
              [125 | _] ->
                new_state = %{state | line: line, column: column, scope: scope, modes: [{:carry_tokens, [eol_token]} | modes]}
                {:ok, eol_token, rest, new_state}
              [41 | _] ->
                new_state = %{state | line: line, column: column, scope: scope, modes: [{:carry_tokens, [eol_token]} | modes]}
                {:ok, eol_token, rest, new_state}
              [62, 62 | _] ->
                new_state = %{state | line: line, column: column, scope: scope, modes: [{:carry_tokens, [eol_token]} | modes]}
                {:ok, eol_token, rest, new_state}
              _ ->
                # If multiple EOLs immediately precede assoc_op (=>), fold all into assoc_op extra
                {after_eols, extra_eols} = count_leading_eols(rest)
                trimmed2 = trim_leading_spaces(after_eols)
                case trimmed2 do
                  [61, 62 | _] ->
                    # total EOLs = current + extra_eols
                    {:eol, {{sl, sc}, _endpos, _}} = eol_token
                    total = 1 + extra_eols
                    carry = {:eol, {{sl, sc}, {sl + total, 1}, total}}
                    spaces = length(after_eols) - length(trimmed2)
                    new_state = %{state | line: line + extra_eols, column: 1 + spaces, scope: scope, modes: [{:carry_tokens, [carry]} | modes]}
                    next(trimmed2, new_state)
                  _ ->
                    # Default: coalesce EOLs, emit one EOL before next token
                    new_state = %{state | line: line, column: column, scope: scope, modes: [{:eol_carry, eol_token} | modes]}
                    next(rest, new_state)
                end
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
            # Emit stored token first, then switch to interp mode with start token pending
            new_state = %{state | line: line, column: column, scope: scope, modes: [{:interp_with_pending, interp_kind, token, delim} | modes]}
            {:ok, stored_token, rest, new_state}
          [stored_token | _remaining_tokens] when interp_kind == :call_identifier ->
            # Emit stored token (dot) first, then queue identifier token; ensure we don't lose it at EOF
            new_state = %{state | line: line, column: column, scope: scope, modes: [{:call_identifier_pending, token} | modes]}
            {:ok, stored_token, rest, new_state}
          _ ->
            # Normal case - no stored tokens, emit start token immediately
            {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:interp, interp_kind, interpolation, delim} | modes]}}
        end

      {:error, {[line: _, column: error_column], _, _}, [?} | _] = string, _tokens, _warnings} when length(modes) > 1 ->
        # Handle empty interpolation case - treat closing } as end_interpolation
        {:ok, {:end_interpolation, {state.line, error_column, nil}, :string}, tl(string), %{state | modes: tl(modes), column: error_column + 1}}

      {:eof, line, column, scope} ->
        {:eof, %{state | line: line, column: column, scope: scope}}
    end
  end
  def next(string, %__MODULE__{modes: [{:interp_with_pending, kind, pending_token, delim} | modes_rest]} = state) do
    # Emit the pending start token and switch to normal interp mode
    new_state = %{state | modes: [{:interp, kind, [], delim} | modes_rest]}
    {:ok, pending_token, string, new_state}
  end
  def next(string, %__MODULE__{modes: [{:call_identifier_pending, pending_token} | modes_rest]} = state) do
    # Emit the pending identifier token and return to normal mode
    new_state = %{state | modes: modes_rest}
    {:ok, pending_token, string, new_state}
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
        end_token_type = case rest do
          [?( | _] -> :quoted_paren_identifier_end;
          [?[ | _] -> :quoted_bracket_identifier_end;
          _ -> :quoted_identifier_end
        end
        end_token = {end_token_type, meta, delim}
        {:ok, end_token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}

      # Sigil heredoc completion (with indentation)
      {:done, meta, _binary_part, indent, rest, line, column, scope} when kind == :sigil ->
        {sigil_atom, start_delim} = sigil_from_interp(interpolation)
        end_token = {:sigil_end, meta, sigil_atom, start_delim, indent}
        case collect_sigil_modifiers(rest, line, column) do
          {:none} ->
            {:ok, end_token, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
          {:mods, mods_token, rest_after, new_column} ->
            # Emit end token first, queue modifiers for next call
            new_state = %{state | line: line, column: column, scope: scope, modes: [{:sigil_mods_pending, mods_token, new_column - column} | modes_rest]}
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
            new_state = %{state | line: line, column: column, scope: scope, modes: [{:sigil_mods_pending, mods_token, new_column - column} | modes_rest]}
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
    # Emit the pending sigil_modifiers token and consume its characters from input
    new_state = %{state | modes: modes_rest, column: state.column + len}
    {_consumed, rest} = Enum.split(string, len)
    {:ok, pending_token, rest, new_state}
  end

  # Helper function to create proper identifier token with multiline support
  defp check_call_identifier_multiline(line, column, end_line, end_column, info, atom, rest, _scope) do
    case rest do
      [?( | _] ->
        {:paren_identifier, {{line, column}, {end_line, end_column}, info}, atom}
      [?[ | _] ->
        {:bracket_identifier, {{line, column}, {end_line, end_column}, info}, atom}
      _ ->
        {:identifier, {{line, column}, {end_line, end_column}, info}, atom}
    end
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
