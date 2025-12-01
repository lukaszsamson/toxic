defmodule Toxic.ToString do
  @moduledoc false

  @doc """
  Converts a list of Toxic tokens back to a string.
  """
  def to_string(tokens) do
    # context is a stack of delimiters
    {io_list, _last_pos, _context} = Enum.reduce(tokens, {[], {1, 1}, []}, &process_token/2)
    IO.iodata_to_binary(io_list)
  end

  defp process_token(token, {acc, {curr_line, curr_col}, context}) do
    {{start_line, start_col}, _meta_end, _} = get_meta(token)

    gap = generate_gap(curr_line, curr_col, start_line, start_col)
    {token_str, new_context} = token_to_string(token, context)

    {end_line, end_col} = advance_position({start_line, start_col}, token_str)

    {[acc, gap, token_str], {end_line, end_col}, new_context}
  end
  
  defp advance_position({line, col}, str) do
    lines = String.split(str, "\n")
    case lines do
      [single] -> 
        {line, col + String.length(single)}
      [first | rest] ->
        new_line = line + length(rest)
        last = List.last(rest)
        new_col = 1 + String.length(last)
        {new_line, new_col}
    end
  end

  defp get_meta(token) do
    case token do
      {_type, meta} -> meta
      {_type, meta, _val} -> meta
      {_type, meta, _val, _extra} -> meta
    end
  end

  defp generate_gap(curr_line, curr_col, start_line, start_col) do
    if start_line > curr_line do
      newlines = String.duplicate("\n", start_line - curr_line)
      spaces = String.duplicate(" ", start_col - 1)
      [newlines, spaces]
    else
      if start_col > curr_col do
        String.duplicate(" ", start_col - curr_col)
      else
        ""
      end
    end
  end

  defp token_to_string(token, context) do
    case token do
      # Literals
      {:int, _meta, chars} -> {List.to_string(chars), context}
      {:flt, _meta, chars} -> {List.to_string(chars), context}
      {:char, meta, _codepoint} -> {get_extra_or_atom(meta, nil), context}

      # Atoms, Keywords
      {:atom, meta, atom} -> 
        name = get_extra_or_atom(meta, atom)
        {":" <> name, context}
        
      {:kw_identifier, meta, atom} -> 
        name = get_extra_or_atom(meta, atom)
        {name <> ":", context}

      {true, _meta} -> {"true", context}
      {false, _meta} -> {"false", context}
      {nil, _meta} -> {"nil", context}

      {:do, _meta} -> {"do", context}
      {:end, _meta} -> {"end", context}
      {:fn, _meta} -> {"fn", context}

      {:block_identifier, _meta, atom} -> {Atom.to_string(atom), context}

      # Identifiers
      {:identifier, meta, atom} -> {get_extra_or_atom(meta, atom), context}
      {:paren_identifier, meta, atom} -> {get_extra_or_atom(meta, atom), context}
      {:bracket_identifier, meta, atom} -> {get_extra_or_atom(meta, atom), context}
      {:do_identifier, meta, atom} -> {get_extra_or_atom(meta, atom), context}
      {:op_identifier, meta, atom} -> {get_extra_or_atom(meta, atom), context}
      {:alias, meta, atom} -> {get_extra_or_atom(meta, atom), context}

      # Operators
      {:unary_op, _meta, op} -> {Atom.to_string(op), context}
      {:dual_op, _meta, op} -> {Atom.to_string(op), context}
      {:mult_op, _meta, op} -> {Atom.to_string(op), context}
      {:rel_op, _meta, op} -> {Atom.to_string(op), context}
      {:comp_op, _meta, op} -> {Atom.to_string(op), context}
      {:and_op, _meta, op} -> {Atom.to_string(op), context}
      {:or_op, _meta, op} -> {Atom.to_string(op), context}
      {:xor_op, _meta, op} -> {Atom.to_string(op), context}
      {:concat_op, _meta, op} -> {Atom.to_string(op), context}
      {:arrow_op, _meta, op} -> {Atom.to_string(op), context}
      {:power_op, _meta, op} -> {Atom.to_string(op), context}
      {:range_op, _meta, op} -> {Atom.to_string(op), context}
      {:in_match_op, _meta, op} -> {Atom.to_string(op), context}
      {:type_op, _meta, op} -> {Atom.to_string(op), context}
      {:stab_op, _meta, op} -> {Atom.to_string(op), context}
      {:match_op, _meta, op} -> {Atom.to_string(op), context}
      {:pipe_op, _meta, op} -> {Atom.to_string(op), context}
      {:ellipsis_op, _meta, op} -> {Atom.to_string(op), context}
      {:ternary_op, _meta, op} -> {Atom.to_string(op), context}
      {:assoc_op, _meta, _} -> {"=>", context}
      {:at_op, _meta, _} -> {"@", context}
      {:capture_op, _meta, _} -> {"&", context}
      {:capture_int, _meta, _} -> {"&", context}

      # Keyword Operators
      {:when_op, _meta, _} -> {"when", context}
      {:in_op, _meta, :in} -> {"in", context}
      {:in_op, _meta, :"not in", _} -> {"not in", context}

      # Punctuation
      {:., _meta} -> {".", context}
      {:dot_call_op, _meta, _} -> {".", context}
      {:",", _meta} -> {",", context}
      {:";", _meta} -> {";", context}
      {:"<<", _meta} -> {"<<", context}
      {:">>", _meta} -> {">>", context}
      {:"(", _meta} -> {"(", context}
      {:")", _meta} -> {")", context}
      {:"[", _meta} -> {"[", context}
      {:"]", _meta} -> {"]", context}
      {:"{", _meta} -> {"{", context}
      {:"}", _meta} -> {"}", context}
      {:%, _meta} -> {"%", context}
      {:%{}, _meta} -> {"%", context}

      # Strings
      {:bin_string_start, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, [delim | context]}
        
      {:bin_string_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:list_string_start, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, [delim | context]}
        
      {:list_string_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}

      {:string_fragment, _meta, binary} -> 
        escaped = escape_fragment(binary, List.first(context))
        {escaped, context}

      {:begin_interpolation, _meta, _kind} -> {"\#{", context}
      {:end_interpolation, _meta, _kind} -> {"}", context}

      # Heredocs
      {:bin_heredoc_start, _meta, _} -> {"\"\"\"", [:heredoc | context]}
      {:list_heredoc_start, _meta, _} -> {"'''", [:heredoc | context]}
      {:bin_heredoc_end, _meta, _, _} -> {"\"\"\"", tl(context)}
      {:list_heredoc_end, _meta, _, _} -> {"'''", tl(context)}

      # Sigils
      {:sigil_start, _meta, sigil_atom, delim} ->
        char = sigil_char(sigil_atom)
        str = "~" <> char <> delim_to_string(delim)
        {str, [delim | context]}

      {:sigil_end, _meta, delim, _indent} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:sigil_modifiers, _meta, modifiers} -> {List.to_string(modifiers), context}

      # Quoted Atoms/Keywords
      {:atom_safe_start, _meta, delim} -> 
        str = ":" <> delim_to_string(delim)
        {str, [delim | context]}
        
      {:atom_unsafe_start, _meta, delim} -> 
        str = ":" <> delim_to_string(delim)
        {str, [delim | context]}
        
      {:atom_safe_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:atom_unsafe_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}

      {:kw_identifier_safe_end, _meta, delim} -> 
        str = delim_to_string(delim) <> ":"
        {str, tl(context)}
        
      {:kw_identifier_unsafe_end, _meta, delim} -> 
        str = delim_to_string(delim) <> ":"
        {str, tl(context)}

      # Quoted Identifiers
      {:quoted_identifier_start, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, [delim | context]}
        
      {:quoted_identifier_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:quoted_paren_identifier_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:quoted_bracket_identifier_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:quoted_do_identifier_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}
        
      {:quoted_op_identifier_end, _meta, delim} -> 
        str = delim_to_string(delim)
        {str, tl(context)}

      # EOL
      {:eol, meta} ->
        count = elem(meta, 2)
        {String.duplicate("\n", count), context}

      # Error
      {:error_token, _meta, _err} -> {"", context}

      _ -> raise "Unknown token: #{inspect(token)}"
    end
  end

  defp sigil_char(atom) do
    "sigil_" <> char = Atom.to_string(atom)
    char
  end

  defp delim_to_string(delim) when is_integer(delim), do: <<delim>>
  defp delim_to_string(delim) when is_binary(delim), do: delim
  defp delim_to_string(delim) when is_list(delim), do: List.to_string(delim)
  
  defp escape_fragment(binary, nil), do: binary
  defp escape_fragment(binary, :heredoc), do: binary # Heredocs don't need escaping of quotes usually, unless triple?
  defp escape_fragment(binary, delim) do
    # Escape delimiter
    delim_str = delim_to_string(delim)
    String.replace(binary, delim_str, "\\" <> delim_str)
  end

  defp get_extra_or_atom(meta, atom) do
    case elem(meta, 2) do
      nil -> Atom.to_string(atom)
      extra when is_list(extra) -> List.to_string(extra)
      extra when is_binary(extra) -> extra
    end
  end
end
