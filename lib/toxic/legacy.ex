defmodule Toxic.Legacy do
  import Toxic.CharacterClassifier, only: [is_horizontal_space: 1]

  @doc """
  Convert range-based tokenizer metadata back to the legacy tuple format.
  """
  def ranges_to_legacy(tokens_with_ranges) do
    ranges_to_legacy_after_collapse(tokens_with_ranges, false, [])
  end

  defp ranges_to_legacy_after_collapse([], _prev_was_eol, acc), do: Enum.reverse(acc)

  defp ranges_to_legacy_after_collapse([{:eol, _} = token | rest], _prev_was_eol, acc) do
    ranges_to_legacy_after_collapse(rest, true, [ranges_token_to_legacy(token) | acc])
  end

  defp ranges_to_legacy_after_collapse([token | rest], prev_was_eol, acc) do
    converted = ranges_token_to_legacy(token)

    adjusted =
      case {prev_was_eol, converted} do
        {true, {type, {line, col, extra}}} when is_integer(col) and col > 1 ->
          {type, {line, col, extra}}

        {true, {type, {line, col, extra}, value}} when is_integer(col) and col > 1 ->
          {type, {line, col, extra}, value}

        {true, {type, {line, col, extra}, a, b}} when is_integer(col) and col > 1 ->
          {type, {line, col, extra}, a, b}

        _ ->
          converted
      end

    ranges_to_legacy_after_collapse(rest, false, [adjusted | acc])
  end

  defp ranges_token_to_legacy({type, meta}) do
    {type, legacy_meta(meta)}
  end

  defp ranges_token_to_legacy({type, meta, value})
       when type in [
              :bin_string,
              :list_string,
              :atom_unsafe,
              :atom_safe,
              :kw_identifier_unsafe,
              :kw_identifier_safe
            ] do
    {type, legacy_meta(meta), ranges_convert_parts(value)}
  end

  defp ranges_token_to_legacy({type, meta, value}) do
    {type, legacy_meta(meta), value}
  end

  defp ranges_token_to_legacy({type, meta, indent, parts})
       when type in [:bin_heredoc, :list_heredoc] do
    {type, legacy_meta(meta), indent, ranges_convert_parts(parts)}
  end

  defp ranges_token_to_legacy(
         {:sigil, meta, sigil_atom, parts, modifiers, indentation, delimiter}
       ) do
    {:sigil, legacy_meta(meta), sigil_atom, ranges_convert_parts(parts), modifiers, indentation,
     delimiter}
  end

  defp legacy_meta({{line, column}, _end_meta, extra}), do: {line, column, extra}
  defp legacy_meta({line, column, extra}), do: {line, column, extra}

  defp ranges_convert_parts(parts) when is_list(parts) do
    Enum.map(parts, &ranges_convert_part/1)
  end

  defp ranges_convert_part({start_meta, end_meta, tokens})
       when is_tuple(start_meta) and is_tuple(end_meta) and is_list(tokens) do
    {legacy_meta(start_meta), legacy_meta(end_meta), ranges_to_legacy(tokens)}
  end

  defp ranges_convert_part(other), do: other

  @doc """
  Collapse linear range markers back into legacy container tokens.
  """
  def collapse_linear_ranges(tokens), do: linear_to_legacy(tokens)

  defp linear_to_legacy(tokens) do
    {out, []} = linear_to_legacy(tokens, [], [])
    Enum.reverse(out)
  end

  defp linear_to_legacy([{:bin_string_start, meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:bin_string, meta, delim, []} | stack])
  end

  defp linear_to_legacy([{:list_string_start, meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:list_string, meta, delim, []} | stack])
  end

  defp linear_to_legacy([{:bin_heredoc_start, meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:bin_heredoc, meta, delim, [], :undefined} | stack])
  end

  defp linear_to_legacy([{:list_heredoc_start, meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:list_heredoc, meta, delim, [], :undefined} | stack])
  end

  defp linear_to_legacy([{:sigil_start, meta, sigil_atom, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:sigil, meta, sigil_atom, delim, [], nil, :pending_end} | stack])
  end

  defp linear_to_legacy([{:quoted_identifier_start, start_meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:quoted_identifier, start_meta, delim, []} | stack])
  end

  defp linear_to_legacy([{:atom_unsafe_start, meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:atom_unsafe, meta, delim, []} | stack])
  end

  defp linear_to_legacy([{:atom_safe_start, meta, delim} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:atom_safe, meta, delim, []} | stack])
  end

  defp linear_to_legacy([{:string_fragment, frag_meta, bin} | rest], out, [
         {:quoted_identifier, meta, delim, parts} | stack
       ]) do
    linear_to_legacy(rest, out, [
      {:quoted_identifier, meta, delim, [{:string_fragment, frag_meta, bin} | parts]} | stack
    ])
  end

  defp linear_to_legacy([{:string_fragment, _frag_meta, bin} | rest], out, [
         {kind, meta, delim, parts} | stack
       ]) do
    linear_to_legacy(rest, out, [{kind, meta, delim, [bin | parts]} | stack])
  end

  defp linear_to_legacy([{:string_fragment, _frag_meta, bin} | rest], out, [
         {kind, meta, delim, parts, extra} | stack
       ])
       when kind in [:bin_heredoc, :list_heredoc] do
    linear_to_legacy(rest, out, [{kind, meta, delim, [bin | parts], extra} | stack])
  end

  defp linear_to_legacy(
         [{:string_fragment, _frag_meta, bin} | rest],
         out,
         [{:sigil, meta, sigil_atom, delim, parts_rev, modifiers, :pending_end} | stack]
       )
       when is_binary(bin) do
    linear_to_legacy(rest, out, [
      {:sigil, meta, sigil_atom, delim, [bin | parts_rev], modifiers, :pending_end} | stack
    ])
  end

  defp linear_to_legacy([{:begin_interpolation, start_meta, _kind} | rest], out, stack) do
    linear_to_legacy(rest, out, [{:interpol, start_meta, []} | stack])
  end

  defp linear_to_legacy(
         [{:end_interpolation, end_meta, _kind} | rest],
         out,
         [{:interpol, start_meta, inner_rev} | stack_rest]
       ) do
    inner_collapsed = linear_to_legacy(Enum.reverse(inner_rev))
    part = {legacy_meta(start_meta), legacy_meta(end_meta), inner_collapsed}

    case stack_rest do
      [{kind, meta, delim, parts} | stack] ->
        linear_to_legacy(rest, out, [{kind, meta, delim, [part | parts]} | stack])

      [{kind, meta, delim, parts, extra} | stack] when kind in [:bin_heredoc, :list_heredoc] ->
        linear_to_legacy(rest, out, [{kind, meta, delim, [part | parts], extra} | stack])

      [{:sigil, meta, sigil_atom, delim, parts, modifiers, :pending_end} | stack] ->
        linear_to_legacy(rest, out, [
          {:sigil, meta, sigil_atom, delim, [part | parts], modifiers, :pending_end} | stack
        ])
    end
  end

  defp linear_to_legacy([token | rest], out, [{:interpol, start_meta, inner} | stack]) do
    linear_to_legacy(rest, out, [{:interpol, start_meta, [token | inner]} | stack])
  end

  defp linear_to_legacy(
         [{:sigil_end, end_meta, _delim, indent} | rest],
         out,
         [{:sigil, meta, sigil_atom, delim, parts_rev, _mods, :pending_end} | stack]
       ) do
    rev_parts =
      case Enum.reverse(parts_rev) do
        [] -> [<<>>]
        other -> other
      end

    parts =
      case indent do
        value when is_integer(value) -> strip_heredoc_indentation(rev_parts, value)
        _ -> rev_parts
      end

    case rest do
      [{:sigil_modifiers, modifiers_meta, modifiers} | tail] ->
        cm0 = combine_range_meta(meta, end_meta)
        cm = combine_range_meta(cm0, modifiers_meta)
        token = {:sigil, cm, sigil_atom, parts, modifiers, indent, delim}

        case stack do
          [{:interpol, interp_meta, inner_rev} | stack_rest] ->
            linear_to_legacy(tail, out, [
              {:interpol, interp_meta, [token | inner_rev]} | stack_rest
            ])

          _ ->
            linear_to_legacy(tail, [token | out], stack)
        end

      _ ->
        cm = combine_range_meta(meta, end_meta)
        token = {:sigil, cm, sigil_atom, parts, [], indent, delim}

        case stack do
          [{:interpol, interp_meta, inner_rev} | stack_rest] ->
            linear_to_legacy(rest, out, [
              {:interpol, interp_meta, [token | inner_rev]} | stack_rest
            ])

          _ ->
            linear_to_legacy(rest, [token | out], stack)
        end
    end
  end

  defp linear_to_legacy(
         [{:bin_string_end, meta_end, _delim1} | rest],
         out,
         [{:bin_string, meta_start, _delim2, parts_rev} | stack]
       ) do
    cm = combine_range_meta(meta_start, meta_end)

    parts =
      case Enum.reverse(parts_rev) do
        [] -> [<<>>]
        rev_parts -> rev_parts
      end

    token = {:bin_string, cm, unescape_binary_parts(parts)}

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:list_string_end, meta_end, _delim1} | rest],
         out,
         [{:list_string, meta_start, _delim2, parts_rev} | stack]
       ) do
    cm = combine_range_meta(meta_start, meta_end)

    parts =
      case Enum.reverse(parts_rev) do
        [] -> [<<>>]
        rev_parts -> rev_parts
      end

    token = {:list_string, cm, unescape_binary_parts(parts)}

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:bin_heredoc_end, meta_end, _delim1, indent} | rest],
         out,
         [{:bin_heredoc, meta_start, _delim2, parts_rev, _} | stack]
       ) do
    cm = combine_range_meta(meta_start, meta_end)
    trimmed = strip_heredoc_indentation(Enum.reverse(parts_rev), indent)
    token = {:bin_heredoc, cm, indent, unescape_binary_parts(trimmed)}

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:list_heredoc_end, meta_end, _delim1, indent} | rest],
         out,
         [{:list_heredoc, meta_start, _delim2, parts_rev, _} | stack]
       ) do
    cm = combine_range_meta(meta_start, meta_end)
    trimmed = strip_heredoc_indentation(Enum.reverse(parts_rev), indent)
    token = {:list_heredoc, cm, indent, unescape_binary_parts(trimmed)}

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:kw_identifier_unsafe_end, meta_end, delim} | rest],
         out,
         [{kind, meta_start, _delim2, parts_rev} | stack]
       )
       when kind in [:bin_string, :list_string] do
    parts = Enum.reverse(parts_rev)
    {{sl, sc}, {el, ec}, _} = combine_range_meta(meta_start, meta_end)
    cm = {{sl, sc}, {el, ec}, delim}
    final = unescape_binary_parts(parts)

    token =
      case final do
        [bin] when is_binary(bin) -> {:kw_identifier, cm, :erlang.binary_to_atom(bin, :utf8)}
        [] -> {:kw_identifier, cm, :""}
        _ -> {:kw_identifier_unsafe, cm, final}
      end

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:kw_identifier_safe_end, meta_end, delim} | rest],
         out,
         [{kind, meta_start, _delim2, parts_rev} | stack]
       )
       when kind in [:bin_string, :list_string] do
    parts = Enum.reverse(parts_rev)
    {{sl, sc}, {el, ec}, _} = combine_range_meta(meta_start, meta_end)
    cm = {{sl, sc}, {el, ec}, delim}
    final = unescape_binary_parts(parts)

    token =
      case final do
        [bin] when is_binary(bin) -> {:kw_identifier, cm, :erlang.binary_to_atom(bin, :utf8)}
        [] -> {:kw_identifier, cm, :""}
        _ -> {:kw_identifier_safe, cm, final}
      end

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:atom_unsafe_end, meta_end, delim} | rest],
         out,
         [{:atom_unsafe, meta_start, _delim2, parts_rev} | stack]
       ) do
    parts = Enum.reverse(parts_rev)
    {{sl, sc}, {el, ec}, _} = combine_range_meta(meta_start, meta_end)
    cm = {{sl, sc}, {el, ec}, delim}
    final = unescape_binary_parts(parts)

    token =
      case final do
        [bin] when is_binary(bin) -> {:atom_quoted, cm, :erlang.binary_to_atom(bin, :utf8)}
        [] -> {:atom_quoted, cm, :""}
        _ -> {:atom_unsafe, cm, final}
      end

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:atom_safe_end, meta_end, delim} | rest],
         out,
         [{:atom_safe, meta_start, _delim2, parts_rev} | stack]
       ) do
    parts = Enum.reverse(parts_rev)
    {{sl, sc}, {el, ec}, _} = combine_range_meta(meta_start, meta_end)
    cm = {{sl, sc}, {el, ec}, delim}
    final = unescape_binary_parts(parts)

    token =
      case final do
        [bin] when is_binary(bin) -> {:atom_quoted, cm, :erlang.binary_to_atom(bin, :utf8)}
        [] -> {:atom_quoted, cm, :""}
        _ -> {:atom_safe, cm, final}
      end

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp linear_to_legacy(
         [{:quoted_identifier_end, end_meta, delim} | rest],
         out,
         [{:quoted_identifier, start_meta, _delim2, parts_rev} | stack]
       ) do
    finalize_quoted_identifier(
      rest,
      out,
      stack,
      start_meta,
      end_meta,
      delim,
      parts_rev,
      :identifier
    )
  end

  defp linear_to_legacy(
         [{:quoted_paren_identifier_end, end_meta, delim} | rest],
         out,
         [{:quoted_identifier, start_meta, _delim2, parts_rev} | stack]
       ) do
    finalize_quoted_identifier(
      rest,
      out,
      stack,
      start_meta,
      end_meta,
      delim,
      parts_rev,
      :paren_identifier
    )
  end

  defp linear_to_legacy(
         [{:quoted_bracket_identifier_end, end_meta, delim} | rest],
         out,
         [{:quoted_identifier, start_meta, _delim2, parts_rev} | stack]
       ) do
    finalize_quoted_identifier(
      rest,
      out,
      stack,
      start_meta,
      end_meta,
      delim,
      parts_rev,
      :bracket_identifier
    )
  end

  defp linear_to_legacy(
         [{:quoted_do_identifier_end, end_meta, delim} | rest],
         out,
         [{:quoted_identifier, start_meta, _delim2, parts_rev} | stack]
       ) do
    finalize_quoted_identifier(
      rest,
      out,
      stack,
      start_meta,
      end_meta,
      delim,
      parts_rev,
      :do_identifier
    )
  end

  defp linear_to_legacy(
         [{:quoted_op_identifier_end, end_meta, delim} | rest],
         out,
         [{:quoted_identifier, start_meta, _delim2, parts_rev} | stack]
       ) do
    finalize_quoted_identifier(
      rest,
      out,
      stack,
      start_meta,
      end_meta,
      delim,
      parts_rev,
      :op_identifier
    )
  end

  defp linear_to_legacy([token | rest], out, stack) do
    linear_to_legacy(rest, [token | out], stack)
  end

  defp linear_to_legacy([], out, []), do: {out, []}

  defp finalize_quoted_identifier(
         rest,
         out,
         stack,
         start_meta,
         end_meta,
         delim,
         parts_rev,
         token_type
       ) do
    parts = Enum.reverse(parts_rev)

    {atom, content_end} =
      case parts do
        [{:string_fragment, frag_meta, content}] ->
          atom = :erlang.binary_to_atom(unescape_bin(content), :utf8)
          {{_, _}, {fel, fec}, _} = frag_meta
          {atom, {fel, fec}}

        [] ->
          {{line, column}, _end_pos, _extra} = end_meta
          {:"", {line, column}}
      end

    {line, column} = content_end
    closing_quote_pos = {line, column + 1}
    {{sl, sc}, _send, _sx} = start_meta
    identifier_meta = {{sl, sc}, closing_quote_pos, delim}
    token = {token_type, identifier_meta, atom}

    case stack do
      [{:interpol, interp_meta, inner_rev} | stack_rest] ->
        linear_to_legacy(rest, out, [{:interpol, interp_meta, [token | inner_rev]} | stack_rest])

      _ ->
        linear_to_legacy(rest, [token | out], stack)
    end
  end

  defp combine_range_meta({{sl, sc}, _send, _sx}, {_estart, {el, ec}, _ex}),
    do: {{sl, sc}, {el, ec}, nil}

  defp strip_heredoc_indentation(parts, indent) do
    {_at_line_start, _spaces_left, out_rev} =
      strip_heredoc_indentation(parts, indent, true, indent, [])

    Enum.reverse(out_rev)
  end

  defp strip_heredoc_indentation([part | rest], indent, at_line_start, spaces_left, acc)
       when is_binary(part) do
    {new_bin, new_at_line_start, new_spaces_left} =
      strip_bin_indent(part, indent, at_line_start, spaces_left)

    strip_heredoc_indentation(rest, indent, new_at_line_start, new_spaces_left, [new_bin | acc])
  end

  defp strip_heredoc_indentation(
         [{_sm, _em, _inner} = interp | rest],
         indent,
         _at_line_start,
         _spaces_left,
         acc
       ) do
    strip_heredoc_indentation(rest, indent, false, 0, [interp | acc])
  end

  defp strip_heredoc_indentation([], _indent, at_line_start, spaces_left, acc) do
    {at_line_start, spaces_left, acc}
  end

  defp strip_bin_indent(bin, indent, at_line_start, spaces_left) when is_binary(bin) do
    strip_bin_indent(:erlang.binary_to_list(bin), indent, at_line_start, spaces_left, [])
  end

  defp strip_bin_indent([?\n | rest], indent, _at_line_start, _spaces_left, acc) do
    strip_bin_indent(rest, indent, true, indent, [?\n | acc])
  end

  defp strip_bin_indent([char | rest], indent, true, spaces_left, acc)
       when spaces_left > 0 and is_horizontal_space(char) do
    strip_bin_indent(rest, indent, true, spaces_left - 1, acc)
  end

  defp strip_bin_indent([char | rest], indent, _at_line_start, spaces_left, acc) do
    strip_bin_indent(rest, indent, false, spaces_left, [char | acc])
  end

  defp strip_bin_indent([], _indent, at_line_start, spaces_left, acc) do
    {acc |> Enum.reverse() |> :erlang.list_to_binary(), at_line_start, spaces_left}
  end

  defp unescape_binary_parts(parts) do
    Enum.map(parts, fn
      part when is_binary(part) -> unescape_bin(part)
      other -> other
    end)
  end

  defp unescape_bin(bin) do
    case Toxic.Unescape.unescape_tokens([bin]) do
      {:ok, [unescaped]} -> unescaped
      _ -> bin
    end
  end
end
