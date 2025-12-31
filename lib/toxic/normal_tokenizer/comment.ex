defmodule Toxic.NormalTokenizer.Comment do
  @moduledoc false
  import Toxic.CharacterClassifier
  import Toxic.Scope

  def tokenize_comment([?\r, ?\n | _] = rest, acc) do
    {rest, Enum.reverse(acc)}
  end

  def tokenize_comment([?\n | _] = rest, acc) do
    {rest, Enum.reverse(acc)}
  end

  def tokenize_comment([h | _rest], _) when bidi(h) do
    {:error, {:comment_invalid_bidi, h}}
  end

  def tokenize_comment([h | _rest], _) when break(h) do
    {:error, {:comment_invalid_linebreak, h}}
  end

  def tokenize_comment([h | rest], acc) do
    tokenize_comment(rest, [h | acc])
  end

  def tokenize_comment([], acc) do
    {[], Enum.reverse(acc)}
  end

  def preserve_comments(
        line,
        column,
        lookbehind,
        comment,
        rest,
        scope(preserve_comments: preserve_comments)
      )
      when is_function(preserve_comments, 5) do
    tokens =
      case lookbehind do
        {nil, _, _} -> []
        {prev, _, _} -> [prev]
      end

    preserve_comments.(line, column, tokens, comment, rest)
  end

  def preserve_comments(_line, _column, _lookbehind, _comment, _rest, _scope) do
    :ok
  end
end
