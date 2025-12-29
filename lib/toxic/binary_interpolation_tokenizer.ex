defmodule Toxic.BinaryInterpolationTokenizer do
  @moduledoc false
  import Toxic.Token
  import Toxic.Scope
  import Toxic.CharacterClassifier

  def next(line, column, scope, interpol, string, last)
      when is_integer(line) and is_integer(column) and is_binary(string) do
    next(string, [], line, column, line, column, scope, interpol, last)
  end

  # 8-byte batch fast path for single-char terminators (64-bit word aligned)
  # Checks all special chars: \, \n, \r, #, and terminator
  def next(
        <<c1, c2, c3, c4, c5, c6, c7, c8, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      )
      when is_integer(last) and
             c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 and
             c5 < 128 and c6 < 128 and c7 < 128 and c8 < 128 and
             c1 != ?\\ and c1 != ?\n and c1 != ?\r and c1 != ?# and c1 != last and
             c2 != ?\\ and c2 != ?\n and c2 != ?\r and c2 != ?# and c2 != last and
             c3 != ?\\ and c3 != ?\n and c3 != ?\r and c3 != ?# and c3 != last and
             c4 != ?\\ and c4 != ?\n and c4 != ?\r and c4 != ?# and c4 != last and
             c5 != ?\\ and c5 != ?\n and c5 != ?\r and c5 != ?# and c5 != last and
             c6 != ?\\ and c6 != ?\n and c6 != ?\r and c6 != ?# and c6 != last and
             c7 != ?\\ and c7 != ?\n and c7 != ?\r and c7 != ?# and c7 != last and
             c8 != ?\\ and c8 != ?\n and c8 != ?\r and c8 != ?# and c8 != last do
    next(
      rest,
      [c8, c7, c6, c5, c4, c3, c2, c1 | buffer],
      line,
      column + 8,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # 8-byte batch fast path for heredocs (triple terminator)
  def next(
        <<c1, c2, c3, c4, c5, c6, c7, c8, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        [h, h, h] = last
      )
      when is_integer(h) and
             c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 and
             c5 < 128 and c6 < 128 and c7 < 128 and c8 < 128 and
             c1 != ?\\ and c1 != ?\n and c1 != ?\r and c1 != ?# and c1 != h and
             c2 != ?\\ and c2 != ?\n and c2 != ?\r and c2 != ?# and c2 != h and
             c3 != ?\\ and c3 != ?\n and c3 != ?\r and c3 != ?# and c3 != h and
             c4 != ?\\ and c4 != ?\n and c4 != ?\r and c4 != ?# and c4 != h and
             c5 != ?\\ and c5 != ?\n and c5 != ?\r and c5 != ?# and c5 != h and
             c6 != ?\\ and c6 != ?\n and c6 != ?\r and c6 != ?# and c6 != h and
             c7 != ?\\ and c7 != ?\n and c7 != ?\r and c7 != ?# and c7 != h and
             c8 != ?\\ and c8 != ?\n and c8 != ?\r and c8 != ?# and c8 != h do
    next(
      rest,
      [c8, c7, c6, c5, c4, c3, c2, c1 | buffer],
      line,
      column + 8,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # 4-byte batch for single-char terminators (fallback when < 8 bytes available)
  def next(
        <<c1, c2, c3, c4, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      )
      when is_integer(last) and
             c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 and
             c1 != ?\\ and c1 != ?\n and c1 != ?\r and c1 != ?# and c1 != last and
             c2 != ?\\ and c2 != ?\n and c2 != ?\r and c2 != ?# and c2 != last and
             c3 != ?\\ and c3 != ?\n and c3 != ?\r and c3 != ?# and c3 != last and
             c4 != ?\\ and c4 != ?\n and c4 != ?\r and c4 != ?# and c4 != last do
    next(
      rest,
      [c4, c3, c2, c1 | buffer],
      line,
      column + 4,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # 4-byte batch for heredocs
  def next(
        <<c1, c2, c3, c4, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        [h, h, h] = last
      )
      when is_integer(h) and
             c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 and
             c1 != ?\\ and c1 != ?\n and c1 != ?\r and c1 != ?# and c1 != h and
             c2 != ?\\ and c2 != ?\n and c2 != ?\r and c2 != ?# and c2 != h and
             c3 != ?\\ and c3 != ?\n and c3 != ?\r and c3 != ?# and c3 != h and
             c4 != ?\\ and c4 != ?\n and c4 != ?\r and c4 != ?# and c4 != h do
    next(
      rest,
      [c4, c3, c2, c1 | buffer],
      line,
      column + 4,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # 2-byte batch for single-char terminators (fallback when < 4 bytes available)
  def next(
        <<c1, c2, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      )
      when is_integer(last) and
             c1 < 128 and c2 < 128 and
             c1 != ?\\ and c1 != ?\n and c1 != ?\r and c1 != ?# and c1 != last and
             c2 != ?\\ and c2 != ?\n and c2 != ?\r and c2 != ?# and c2 != last do
    next(
      rest,
      [c2, c1 | buffer],
      line,
      column + 2,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # 2-byte batch for heredocs
  def next(
        <<c1, c2, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        [h, h, h] = last
      )
      when is_integer(h) and
             c1 < 128 and c2 < 128 and
             c1 != ?\\ and c1 != ?\n and c1 != ?\r and c1 != ?# and c1 != h and
             c2 != ?\\ and c2 != ?\n and c2 != ?\r and c2 != ?# and c2 != h do
    next(
      rest,
      [c2, c1 | buffer],
      line,
      column + 2,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # Terminators - empty input with non-empty buffer

  def next(
        <<>>,
        buffer = [_ | _],
        line,
        column,
        start_line,
        start_column,
        scope,
        _interpol,
        _last
      ) do
    {:fragment, meta(start_line, start_column, line, column, nil),
     Toxic.Util.characters_to_binary(Enum.reverse(buffer)), <<>>, line, column, scope}
  end

  # Single character terminator with non-empty buffer
  def next(
        <<last, _rest::binary>> = original,
        buffer = [_ | _],
        line,
        column,
        start_line,
        start_column,
        scope,
        _interpol,
        last
      )
      when is_integer(last) do
    {:fragment, meta(start_line, start_column, line, column, nil),
     Toxic.Util.characters_to_binary(Enum.reverse(buffer)), original, line, column, scope}
  end

  # Single character terminator with empty buffer
  def next(
        <<last, rest::binary>>,
        [],
        line,
        column,
        _start_line,
        _start_column,
        scope,
        _interpol,
        last
      )
      when is_integer(last) do
    {:done, meta(line, column, 1, nil), nil, rest, line, column + 1, scope}
  end

  # Triple terminator (heredoc) with empty buffer
  def next(
        <<last, last, last, rest::binary>>,
        [],
        line,
        column,
        _start_line,
        _start_column,
        scope = scope(column: base_column, allow_triple_terminator: true),
        _interpol,
        [last, last, last]
      )
      when is_integer(last) do
    scope = scope(scope, allow_triple_terminator: false)
    {:done, meta(line, column, 3, nil), column - base_column, rest, line, column + 3, scope}
  end

  # Going through the string

  # Escaped CRLF
  def next(
        <<?\\, ?\r, ?\n, rest::binary>>,
        buffer,
        line,
        _column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      ) do
    extract_nl(
      rest,
      [?\n, ?\r, ?\\ | buffer],
      line,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # Escaped LF
  def next(
        <<?\\, ?\n, rest::binary>>,
        buffer,
        line,
        _column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      ) do
    extract_nl(rest, [?\n, ?\\ | buffer], line, start_line, start_column, scope, interpol, last)
  end

  # Plain newline
  def next(
        <<?\n, rest::binary>>,
        buffer,
        line,
        _column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      ) do
    extract_nl(rest, [?\n | buffer], line, start_line, start_column, scope, interpol, last)
  end

  # Escaped single terminator
  def next(
        <<?\\, last, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      )
      when is_integer(last) do
    new_scope =
      if not interpol do
        warning = Toxic.Warning.deprecated_sigil_escape(line, column, last)
        Toxic.Scope.prepend_warning(warning, scope)
      else
        scope
      end

    next(
      rest,
      [last | buffer],
      line,
      column + 2,
      start_line,
      start_column,
      new_scope,
      interpol,
      last
    )
  end

  # Escaped triple terminator (heredoc)
  def next(
        <<?\\, last, last, last, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        [last, last, last] = all
      )
      when is_integer(last) do
    next(
      rest,
      [last, last, last | buffer],
      line,
      column + 4,
      start_line,
      start_column,
      scope,
      interpol,
      all
    )
  end

  # Escaped interpolation start
  def next(
        <<?\\, ?#, ?{, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        true,
        last
      ) do
    next(
      rest,
      [?{, ?#, ?\\ | buffer],
      line,
      column + 3,
      start_line,
      start_column,
      scope,
      true,
      last
    )
  end

  # Interpolation start with non-empty buffer
  def next(
        <<?#, ?{, _::binary>> = rest,
        buffer = [_ | _],
        line,
        column,
        start_line,
        start_column,
        scope,
        true,
        _last
      ) do
    content = Toxic.Util.characters_to_binary(Enum.reverse(buffer))

    {:fragment, meta(start_line, start_column, line, column, nil), content, rest, line,
     column, scope}
  end

  # Interpolation start with empty buffer
  def next(
        <<?#, ?{, rest::binary>>,
        [],
        line,
        column,
        _start_line,
        _start_column,
        scope,
        true,
        _last
      ) do
    {:begin_interpolation, meta(line, column, 2, nil), rest, line, column + 2, scope}
  end

  # Escape character - extract the escaped char
  def next(
        <<?\\, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      ) do
    extract_char(
      rest,
      [?\\ | buffer],
      line,
      column + 1,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # Single ASCII character fallback
  def next(
        <<char, rest::binary>>,
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      )
      when char < 128 do
    next(
      rest,
      [char | buffer],
      line,
      column + 1,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  # Non-ASCII - use grapheme extraction
  def next(rest, buffer, line, column, start_line, start_column, scope, interpol, last) do
    extract_char(rest, buffer, line, column, start_line, start_column, scope, interpol, last)
  end

  defp extract_char(<<>>, buffer, line, column, start_line, start_column, scope, interpol, last) do
    next(<<>>, buffer, line, column, start_line, start_column, scope, interpol, last)
  end

  defp extract_char(rest, buffer, line, column, start_line, start_column, scope, interpol, last) do
    case :unicode_util.gc(rest) do
      [char | _] when bidi(char) or break(char) ->
        char_hex = String.upcase(Integer.to_string(char, 16))
        char_hex_padded = String.pad_leading(char_hex, 4, "0")
        token = ~c"\\u" ++ String.to_charlist(char_hex_padded)

        # Adjust line number for heredoc content (which has prepended newline)
        # If we're processing heredoc content and line > start_line, subtract 1
        # to account for the prepended newline
        adjusted_line = if line > start_line, do: line - 1, else: line

        code = if bidi(char), do: :comment_invalid_bidi, else: :comment_invalid_linebreak

        err = %Toxic.Error{
          code: code,
          domain: :string,
          token_display: token,
          details: %{line: adjusted_line, column: column}
        }

        {:error, err}

      [char | new_rest] when is_list(char) ->
        next(
          new_rest,
          :lists.reverse(char, buffer),
          line,
          column + 1,
          start_line,
          start_column,
          scope,
          interpol,
          last
        )

      [char | new_rest] when is_integer(char) ->
        next(
          new_rest,
          [char | buffer],
          line,
          column + 1,
          start_line,
          start_column,
          scope,
          interpol,
          last
        )

      [] ->
        next(<<>>, buffer, line, column, start_line, start_column, scope, interpol, last)
    end
  end

  # Handle newlines for heredocs with triple terminators
  defp extract_nl(
         rest,
         buffer,
         line,
         start_line,
         start_column,
         scope = scope(column: base_column),
         interpol,
         [h, h, h] = last
       )
       when is_integer(h) do
    case strip_horizontal_space_bin(rest, [], base_column) do
      {<<^h, ^h, ^h, _::binary>> = original, _new_buffer, column} ->
        scope = scope(scope, allow_triple_terminator: true)

        {:fragment, meta(start_line, start_column, line + 1, column, nil),
         Toxic.Util.characters_to_binary(Enum.reverse(buffer)), original, line + 1,
         column, scope}

      {new_rest, new_buffer, column} ->
        next(
          new_rest,
          Enum.reverse(new_buffer, buffer),
          line + 1,
          column,
          start_line,
          start_column,
          scope,
          interpol,
          last
        )
    end
  end

  # Handle newlines for single character terminators
  defp extract_nl(
         rest,
         buffer,
         line,
         start_line,
         start_column,
         scope = scope(column: column),
         interpol,
         last
       ) do
    next(
      rest,
      buffer,
      line + 1,
      column,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  defp strip_horizontal_space_bin(<<h, h, h, h, h, h, h, h, rest::binary>>, buffer, counter)
       when is_horizontal_space(h) do
    strip_horizontal_space_bin(rest, [h, h, h, h, h, h, h, h | buffer], counter + 8)
  end

  defp strip_horizontal_space_bin(<<h, h, h, h, rest::binary>>, buffer, counter)
       when is_horizontal_space(h) do
    strip_horizontal_space_bin(rest, [h, h, h, h | buffer], counter + 4)
  end

  defp strip_horizontal_space_bin(<<h, h, rest::binary>>, buffer, counter)
       when is_horizontal_space(h) do
    strip_horizontal_space_bin(rest, [h, h | buffer], counter + 2)
  end

  defp strip_horizontal_space_bin(<<h, rest::binary>>, buffer, counter)
       when is_horizontal_space(h) do
    strip_horizontal_space_bin(rest, [h | buffer], counter + 1)
  end

  defp strip_horizontal_space_bin(rest, buffer, counter) when is_binary(rest) do
    {rest, buffer, counter}
  end
end
