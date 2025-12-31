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

  def consume_one([], line, column, _scope) do
    {[], line, column}
  end

  def consume_one(rest, line, column, scope) do
    scope(column: base_column) = scope

    case :unicode_util.gc(rest) do
      [cluster | new_rest] when is_list(cluster) ->
        {line, col} = advance_pos_cluster(cluster, line, column, base_column)
        {new_rest, line, col}

      [codepoint | new_rest] when is_integer(codepoint) ->
        {line, col} = advance_pos(codepoint, line, column, base_column)
        {new_rest, line, col}

      [] ->
        {[], line, column}
    end
  end

  def consume_one(rest, %Driver{} = state) do
    consume_one(rest, state.line, state.column, state.scope)
  end

  def consume_one(rest, %{line: line, column: column, scope: scope}) do
    consume_one(rest, line, column, scope)
  end

  def scan_to_sync(rest, line, column, scope, contexts, cfg) do
    do_scan_to_sync(rest, line, column, scope, contexts, cfg, 0)
  end

  def scan_to_sync(rest, %Driver{} = state) do
    cfg = %{error_sync: state.error_sync, error_max_skip: state.error_max_skip}
    scan_to_sync(rest, state.line, state.column, state.scope, state.contexts, cfg)
  end

  def scan_to_sync(
        rest,
        %{line: line, column: column, scope: scope, contexts: contexts,
          error_sync: sync, error_max_skip: max}
      ) do
    cfg = %{error_sync: sync, error_max_skip: max}
    scan_to_sync(rest, line, column, scope, contexts, cfg)
  end

  defp do_scan_to_sync(rest, line, column, scope, _contexts, cfg, scanned)
       when scanned >= cfg.error_max_skip do
    consume_one(rest, line, column, scope)
  end

  defp do_scan_to_sync([], line, column, _scope, _contexts, _cfg, _scanned),
    do: {[], line, column}

  defp do_scan_to_sync(list = [h | _t], line, column, scope, contexts, cfg, scanned) do
    stop? =
      stop_at_semicolon?(h, cfg) or
        stop_at_newline?(list, cfg) or
        stop_at_comma?(h, cfg) or
        stop_at_comment?(h, cfg) or
        stop_at_whitespace?(h, cfg) or
        stop_at_closer?(list, scope, contexts, cfg)

    if stop? do
      {list, line, column}
    else
      case :unicode_util.gc(list) do
        [cluster | rest2] when is_list(cluster) ->
          scope(column: base_column) = scope

          {next_line, next_col} = advance_pos_cluster(cluster, line, column, base_column)

          do_scan_to_sync(rest2, next_line, next_col, scope, contexts, cfg, scanned + 1)

        [codepoint | rest2] when is_integer(codepoint) ->
          scope(column: base_column) = scope
          {next_line, next_col} = advance_pos(codepoint, line, column, base_column)
          do_scan_to_sync(rest2, next_line, next_col, scope, contexts, cfg, scanned + 1)

        [] ->
          {list, line, column}
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

  defp stop_at_semicolon?(ch, cfg) do
    :semicolon in cfg.error_sync and ch == ?;
  end

  defp stop_at_comma?(ch, cfg) do
    :comma in cfg.error_sync and ch == ?,
  end

  defp stop_at_comment?(ch, cfg), do: :comment in cfg.error_sync and ch == ?#

  defp stop_at_whitespace?(h, cfg), do: :whitespace in cfg.error_sync and is_horizontal_space(h)

  defp stop_at_newline?([?\n | _], cfg), do: :newline in cfg.error_sync
  defp stop_at_newline?([?\r, ?\n | _], cfg), do: :newline in cfg.error_sync
  defp stop_at_newline?(_, _cfg), do: false

  defp stop_at_closer?(rest, scope, contexts, cfg) do
    if :closer in cfg.error_sync do
      case Driver.current_terminators_from(scope, contexts) do
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
  def consume_one_bin(<<>>, line, column, _scope) do
    {<<>>, line, column}
  end

  # ASCII fast path - single byte, no grapheme cluster lookup needed
  def consume_one_bin(<<byte, rest::binary>>, line, column, scope) when byte < 128 do
    scope(column: base_column) = scope
    {line, col} = advance_pos(byte, line, column, base_column)
    {rest, line, col}
  end

  # Non-ASCII - use grapheme cluster handling with :unicode_util.gc
  def consume_one_bin(rest, line, column, scope) when is_binary(rest) do
    scope(column: base_column) = scope

    case :unicode_util.gc(rest) do
      [cluster | new_rest] when is_list(cluster) ->
        {line, col} = advance_pos_cluster(cluster, line, column, base_column)
        {new_rest, line, col}

      [codepoint | new_rest] when is_integer(codepoint) ->
        {line, col} = advance_pos(codepoint, line, column, base_column)
        {new_rest, line, col}

      [] ->
        {<<>>, line, column}
    end
  end

  def consume_one_bin(rest, %Driver{} = state) do
    consume_one_bin(rest, state.line, state.column, state.scope)
  end

  def consume_one_bin(rest, %{line: line, column: column, scope: scope}) do
    consume_one_bin(rest, line, column, scope)
  end

  @doc """
  Scan to sync point in binary input.
  Uses ASCII fast path for common cases.
  """
  def scan_to_sync_bin(rest, line, column, scope, contexts, cfg) when is_binary(rest) do
    do_scan_to_sync_bin(rest, line, column, scope, contexts, cfg, 0)
  end

  def scan_to_sync_bin(rest, %Driver{} = state) when is_binary(rest) do
    cfg = %{error_sync: state.error_sync, error_max_skip: state.error_max_skip}
    scan_to_sync_bin(rest, state.line, state.column, state.scope, state.contexts, cfg)
  end

  def scan_to_sync_bin(
        rest,
        %{line: line, column: column, scope: scope, contexts: contexts,
          error_sync: sync, error_max_skip: max}
      )
      when is_binary(rest) do
    cfg = %{error_sync: sync, error_max_skip: max}
    scan_to_sync_bin(rest, line, column, scope, contexts, cfg)
  end

  defp do_scan_to_sync_bin(rest, line, column, scope, _contexts, cfg, scanned)
       when scanned >= cfg.error_max_skip do
    consume_one_bin(rest, line, column, scope)
  end

  defp do_scan_to_sync_bin(<<>>, line, column, _scope, _contexts, _cfg, _scanned),
    do: {<<>>, line, column}

  # ASCII fast path - check sync points with single-byte patterns
  defp do_scan_to_sync_bin(<<h, _::binary>> = bin, line, column, scope, contexts, cfg, scanned)
       when h < 128 do
    stop? =
      stop_at_semicolon?(h, cfg) or
        stop_at_newline_bin?(bin, cfg) or
        stop_at_comma?(h, cfg) or
        stop_at_comment?(h, cfg) or
        stop_at_whitespace?(h, cfg) or
        stop_at_closer_bin?(bin, scope, contexts, cfg)

    if stop? do
      {bin, line, column}
    else
      scope(column: base_column) = scope
      {next_line, next_col} = advance_pos(h, line, column, base_column)
      <<_, rest::binary>> = bin
      do_scan_to_sync_bin(rest, next_line, next_col, scope, contexts, cfg, scanned + 1)
    end
  end

  # Non-ASCII - use grapheme handling with :unicode_util.gc
  defp do_scan_to_sync_bin(bin, line, column, scope, contexts, cfg, scanned)
       when is_binary(bin) do
    case :unicode_util.gc(bin) do
      [cluster | rest] when is_list(cluster) ->
        scope(column: base_column) = scope
        {next_line, next_col} = advance_pos_cluster(cluster, line, column, base_column)
        do_scan_to_sync_bin(rest, next_line, next_col, scope, contexts, cfg, scanned + 1)

      [codepoint | rest] when is_integer(codepoint) ->
        scope(column: base_column) = scope
        {next_line, next_col} = advance_pos(codepoint, line, column, base_column)
        do_scan_to_sync_bin(rest, next_line, next_col, scope, contexts, cfg, scanned + 1)

      [] ->
        {bin, line, column}
    end
  end

  defp stop_at_newline_bin?(<<?\n, _::binary>>, cfg), do: :newline in cfg.error_sync

  defp stop_at_newline_bin?(<<?\r, ?\n, _::binary>>, cfg), do: :newline in cfg.error_sync

  defp stop_at_newline_bin?(_, _cfg), do: false

  defp stop_at_closer_bin?(rest, scope, contexts, cfg) when is_binary(rest) do
    if :closer in cfg.error_sync do
      case Driver.current_terminators_from(scope, contexts) do
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
