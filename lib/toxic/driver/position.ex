defmodule Toxic.Driver.Position do
  @moduledoc false

  import Toxic.CharacterClassifier
  import Toxic.Scope

  alias Toxic.Driver

  # ============================================================================
  # Charlist variants (original)
  # ============================================================================

  def consume_until_newline([?\n | rest]), do: {rest, true}
  def consume_until_newline([?\r, ?\n | rest]), do: {rest, true}
  def consume_until_newline([_ | rest]), do: consume_until_newline(rest)
  def consume_until_newline([]), do: {[], false}

  def consume_one([], state) do
    {[], state.line, state.column}
  end

  def consume_one(rest, state) do
    scope(column: base_column) = state.scope

    case :unicode_util.gc(rest) do
      [cluster | new_rest] when is_list(cluster) ->
        {line, col} = advance_pos_cluster(cluster, state.line, state.column, base_column)
        {new_rest, line, col}

      [codepoint | new_rest] when is_integer(codepoint) ->
        {line, col} = advance_pos(codepoint, state.line, state.column, base_column)
        {new_rest, line, col}

      [] ->
        {[], state.line, state.column}
    end
  end

  def scan_to_sync(rest, state) do
    do_scan_to_sync(rest, state, 0)
  end

  defp do_scan_to_sync(rest, state, scanned) when scanned >= state.error_max_skip do
    consume_one(rest, state)
  end

  defp do_scan_to_sync([], state, _scanned), do: {[], state.line, state.column}

  defp do_scan_to_sync(list = [h | _t], state, scanned) do
    stop? =
      stop_at_semicolon?(h, state) or
        stop_at_newline?(list, state) or
        stop_at_comma?(h, state) or
        stop_at_comment?(h, state) or
        stop_at_whitespace?(h, state) or
        stop_at_closer?(list, state)

    if stop? do
      {list, state.line, state.column}
    else
      case :unicode_util.gc(list) do
        [cluster | rest2] when is_list(cluster) ->
          scope(column: base_column) = state.scope

          {next_line, next_col} =
            advance_pos_cluster(cluster, state.line, state.column, base_column)

          do_scan_to_sync(rest2, %{state | line: next_line, column: next_col}, scanned + 1)

        [codepoint | rest2] when is_integer(codepoint) ->
          scope(column: base_column) = state.scope
          {next_line, next_col} = advance_pos(codepoint, state.line, state.column, base_column)
          do_scan_to_sync(rest2, %{state | line: next_line, column: next_col}, scanned + 1)

        [] ->
          {list, state.line, state.column}
      end
    end
  end

  defp advance_pos(?\n, line, _col, base_column), do: {line + 1, base_column}
  defp advance_pos(_ch, line, col, _base_column), do: {line, col + 1}

  defp advance_pos_cluster(cluster, line, col, base_column) do
    if Enum.any?(cluster, &(&1 == ?\n)) do
      {line + 1, base_column}
    else
      {line, col + 1}
    end
  end

  defp stop_at_semicolon?(ch, %Driver{error_sync: sync}) do
    :semicolon in sync and ch == ?;
  end

  defp stop_at_comma?(ch, %Driver{error_sync: sync}) do
    :comma in sync and ch == ?,
  end

  defp stop_at_comment?(ch, %Driver{error_sync: sync}), do: :comment in sync and ch == ?#

  defp stop_at_whitespace?(h, %Driver{error_sync: sync}),
    do: :whitespace in sync and is_horizontal_space(h)

  defp stop_at_newline?([?\n | _], %Driver{error_sync: sync}), do: :newline in sync
  defp stop_at_newline?([?\r, ?\n | _], %Driver{error_sync: sync}), do: :newline in sync
  defp stop_at_newline?(_, _state), do: false

  defp stop_at_closer?(rest, %Driver{error_sync: sync} = state) do
    if :closer in sync do
      case Driver.current_terminators(state) do
        [{start_token, _meta, _indent} | _] ->
          expected = Driver.closing_for(start_token)
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

  defp starts_with_char?([h | _], ch), do: h == ch

  defp starts_with_list?(_list, []), do: true
  defp starts_with_list?([h | t1], [h | t2]), do: starts_with_list?(t1, t2)
  defp starts_with_list?(_, _), do: false

  defp terminator_chars(delimiter) when is_atom(delimiter) do
    delimiter
    |> Atom.to_string()
    |> String.to_charlist()
  end

  # ============================================================================
  # Binary variants (for lexer_backend: :binary)
  # ============================================================================

  @doc """
  Consume until newline in binary input.
  """
  def consume_until_newline_bin(<<?\n, rest::binary>>), do: {rest, true}
  def consume_until_newline_bin(<<?\r, ?\n, rest::binary>>), do: {rest, true}
  def consume_until_newline_bin(<<_, rest::binary>>), do: consume_until_newline_bin(rest)
  def consume_until_newline_bin(<<>>), do: {<<>>, false}

  @doc """
  Consume one grapheme from binary input.
  Uses ASCII fast path for single-byte characters.
  """
  def consume_one_bin(<<>>, state) do
    {<<>>, state.line, state.column}
  end

  # ASCII fast path - single byte, no grapheme cluster lookup needed
  def consume_one_bin(<<byte, rest::binary>>, state) when byte < 128 do
    scope(column: base_column) = state.scope
    {line, col} = advance_pos(byte, state.line, state.column, base_column)
    {rest, line, col}
  end

  # Non-ASCII - use grapheme cluster handling with :unicode_util.gc
  def consume_one_bin(rest, state) when is_binary(rest) do
    scope(column: base_column) = state.scope

    case :unicode_util.gc(rest) do
      [cluster | new_rest] when is_list(cluster) ->
        {line, col} = advance_pos_cluster(cluster, state.line, state.column, base_column)
        {new_rest, line, col}

      [codepoint | new_rest] when is_integer(codepoint) ->
        {line, col} = advance_pos(codepoint, state.line, state.column, base_column)
        {new_rest, line, col}

      [] ->
        {<<>>, state.line, state.column}
    end
  end

  @doc """
  Scan to sync point in binary input.
  Uses ASCII fast path for common cases.
  """
  def scan_to_sync_bin(rest, state) when is_binary(rest) do
    do_scan_to_sync_bin(rest, state, 0)
  end

  defp do_scan_to_sync_bin(rest, state, scanned) when scanned >= state.error_max_skip do
    consume_one_bin(rest, state)
  end

  defp do_scan_to_sync_bin(<<>>, state, _scanned), do: {<<>>, state.line, state.column}

  # ASCII fast path - check sync points with single-byte patterns
  defp do_scan_to_sync_bin(<<h, _::binary>> = bin, state, scanned) when h < 128 do
    stop? =
      stop_at_semicolon?(h, state) or
        stop_at_newline_bin?(bin, state) or
        stop_at_comma?(h, state) or
        stop_at_comment?(h, state) or
        stop_at_whitespace?(h, state) or
        stop_at_closer_bin?(bin, state)

    if stop? do
      {bin, state.line, state.column}
    else
      scope(column: base_column) = state.scope
      {next_line, next_col} = advance_pos(h, state.line, state.column, base_column)
      <<_, rest::binary>> = bin
      do_scan_to_sync_bin(rest, %{state | line: next_line, column: next_col}, scanned + 1)
    end
  end

  # Non-ASCII - use grapheme handling with :unicode_util.gc
  defp do_scan_to_sync_bin(bin, state, scanned) when is_binary(bin) do
    case :unicode_util.gc(bin) do
      [cluster | rest] when is_list(cluster) ->
        scope(column: base_column) = state.scope
        {next_line, next_col} = advance_pos_cluster(cluster, state.line, state.column, base_column)
        do_scan_to_sync_bin(rest, %{state | line: next_line, column: next_col}, scanned + 1)

      [codepoint | rest] when is_integer(codepoint) ->
        scope(column: base_column) = state.scope
        {next_line, next_col} = advance_pos(codepoint, state.line, state.column, base_column)
        do_scan_to_sync_bin(rest, %{state | line: next_line, column: next_col}, scanned + 1)

      [] ->
        {bin, state.line, state.column}
    end
  end

  defp stop_at_newline_bin?(<<?\n, _::binary>>, %Driver{error_sync: sync}), do: :newline in sync

  defp stop_at_newline_bin?(<<?\r, ?\n, _::binary>>, %Driver{error_sync: sync}),
    do: :newline in sync

  defp stop_at_newline_bin?(_, _state), do: false

  defp stop_at_closer_bin?(rest, %Driver{error_sync: sync} = state) when is_binary(rest) do
    if :closer in sync do
      case Driver.current_terminators(state) do
        [{start_token, _meta, _indent} | _] ->
          expected = Driver.closing_for(start_token)
          closer_starts_with_bin?(rest, expected)

        _ ->
          false
      end
    else
      false
    end
  end

  defp closer_starts_with_bin?(bin, :")"), do: String.starts_with?(bin, ")")
  defp closer_starts_with_bin?(bin, :"]"), do: String.starts_with?(bin, "]")
  defp closer_starts_with_bin?(bin, :"}"), do: String.starts_with?(bin, "}")
  defp closer_starts_with_bin?(bin, :">>"), do: String.starts_with?(bin, ">>")
  defp closer_starts_with_bin?(bin, :end), do: String.starts_with?(bin, "end")

  defp closer_starts_with_bin?(bin, expected) when is_atom(expected) do
    String.starts_with?(bin, Atom.to_string(expected))
  end
end
