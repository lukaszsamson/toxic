defmodule Toxic.Interpolation do
  import Toxic.Token
  import Toxic.Scope
  import Toxic.CharacterClassifier

  def tokenize_single(line, column, scope, interpol, string, last)
      when is_integer(line) and is_integer(column) do
    tokenize_single(string, [], line, column, line, column, scope, interpol, last)
  end

  # Terminators

  def tokenize_single(
        [],
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
     Toxic.Util.characters_to_binary(Enum.reverse(buffer)), [], line, column, scope}
  end

  # This cannot happen
  # def tokenize_single(
  #       [],
  #       [],
  #       _line,
  #       _column,
  #       _start_line,
  #       _start_column,
  #       scope(cursor_completion: false),
  #       _interpol,
  #       _last
  #     ) do
  #   :eof
  # end

  def tokenize_single(
        [last | rest],
        buffer = [_ | _],
        line,
        column,
        start_line,
        start_column,
        scope,
        _interpol,
        last
      ) do
    {:fragment, meta(start_line, start_column, line, column, nil),
     Toxic.Util.characters_to_binary(Enum.reverse(buffer)), [last | rest], line, column, scope}
  end

  def tokenize_single(
        [last | rest],
        [],
        line,
        column,
        _start_line,
        _start_column,
        scope,
        _interpol,
        last
      ) do
    {:done, meta(line, column, 1, nil), nil, rest, line, column + 1, scope}
  end

  def tokenize_single(
        [last, last, last | rest],
        [],
        line,
        column,
        _start_line,
        _start_column,
        scope,
        _interpol,
        [last, last, last]
      ) do
    {:done, meta(line, column, 3, nil), column - 1, rest, line, column + 3, scope}
  end

  # Going through the string

  def tokenize_single(
        [?\\, ?\r, ?\n | rest],
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

  def tokenize_single(
        [?\\, ?\n | rest],
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

  def tokenize_single(
        [?\n | rest],
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

  def tokenize_single(
        [?\\, last | rest],
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      ) do
    new_scope =
      if not interpol do
        warning = Toxic.Warning.deprecated_sigil_escape(line, column, last)
        Toxic.Scope.prepend_warning(warning, scope)
      else
        scope
      end

    tokenize_single(
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

  def tokenize_single(
        [?\\, last, last, last | rest],
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        [last, last, last] = all
      ) do
    tokenize_single(
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

  def tokenize_single(
        [?\\, ?#, ?{ | rest],
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        true,
        last
      ) do
    tokenize_single(
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

  def tokenize_single(
        [?#, ?{ | rest],
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

    {:fragment, meta(start_line, start_column, line, column, nil), content, [?#, ?{ | rest], line,
     column, scope}
  end

  def tokenize_single(
        [?#, ?{ | rest],
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

  def tokenize_single(
        [?\\ | rest],
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

  # Catch all clause

  def tokenize_single(
        [char1, char2 | rest],
        buffer,
        line,
        column,
        start_line,
        start_column,
        scope,
        interpol,
        last
      )
      when char1 <= 255 and char2 <= 255 do
    tokenize_single(
      [char2 | rest],
      [char1 | buffer],
      line,
      column + 1,
      start_line,
      start_column,
      scope,
      interpol,
      last
    )
  end

  def tokenize_single(rest, buffer, line, column, start_line, start_column, scope, interpol, last) do
    extract_char(rest, buffer, line, column, start_line, start_column, scope, interpol, last)
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
        domain = :string

        err = %Toxic.Error{
          code: code,
          domain: domain,
          token_display: token,
          details: %{line: adjusted_line, column: column}
        }

        {:error, err}

      [char | new_rest] when is_list(char) ->
        tokenize_single(
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
        tokenize_single(
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
        tokenize_single([], buffer, line, column, start_line, start_column, scope, interpol, last)
    end
  end

  defp extract_nl(rest, buffer, line, start_line, start_column, scope, interpol, [h, h, h] = last) do
    case strip_horizontal_space(rest, buffer, 1) do
      {[^h, ^h, ^h | new_rest], _new_buffer, column} ->
        {:fragment, meta(start_line, start_column, line + 1, 1, nil),
         Toxic.Util.characters_to_binary(Enum.reverse(buffer)), [h, h, h | new_rest], line + 1,
         column, scope}

      {new_rest, new_buffer, column} ->
        tokenize_single(
          new_rest,
          new_buffer,
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
    # TODO: all newlines should use scope column instead of hardcoded 1
    tokenize_single(
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

  defp strip_horizontal_space([h | t], buffer, counter) when is_horizontal_space(h) do
    strip_horizontal_space(t, [h | buffer], counter + 1)
  end

  defp strip_horizontal_space(t, buffer, counter) do
    {t, buffer, counter}
  end
end
