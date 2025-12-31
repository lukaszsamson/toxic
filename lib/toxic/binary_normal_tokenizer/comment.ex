defmodule Toxic.BinaryNormalTokenizer.Comment do
  @moduledoc false
  import Toxic.CharacterClassifier
  import Toxic.Scope

  # Terminators - return charlist (not binary) for preserve_comments compatibility
  def tokenize_comment(<<?\r, ?\n, _::binary>> = rest, acc) do
    {rest, :lists.reverse(acc)}
  end

  def tokenize_comment(<<?\n, _::binary>> = rest, acc) do
    {rest, :lists.reverse(acc)}
  end

  # 8-byte ASCII fast path - comments are typically ASCII
  def tokenize_comment(<<c1, c2, c3, c4, c5, c6, c7, c8, rest::binary>>, acc)
      when c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 and
             c5 < 128 and c6 < 128 and c7 < 128 and c8 < 128 and
             c1 != ?\n and c1 != ?\r and
             c2 != ?\n and c2 != ?\r and
             c3 != ?\n and c3 != ?\r and
             c4 != ?\n and c4 != ?\r and
             c5 != ?\n and c5 != ?\r and
             c6 != ?\n and c6 != ?\r and
             c7 != ?\n and c7 != ?\r and
             c8 != ?\n and c8 != ?\r do
    tokenize_comment(rest, [c8, c7, c6, c5, c4, c3, c2, c1 | acc])
  end

  # 4-byte ASCII fast path
  def tokenize_comment(<<c1, c2, c3, c4, rest::binary>>, acc)
      when c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 and
             c1 != ?\n and c1 != ?\r and
             c2 != ?\n and c2 != ?\r and
             c3 != ?\n and c3 != ?\r and
             c4 != ?\n and c4 != ?\r do
    tokenize_comment(rest, [c4, c3, c2, c1 | acc])
  end

  # 2-byte ASCII fast path
  def tokenize_comment(<<c1, c2, rest::binary>>, acc)
      when c1 < 128 and c2 < 128 and
             c1 != ?\n and c1 != ?\r and
             c2 != ?\n and c2 != ?\r do
    tokenize_comment(rest, [c2, c1 | acc])
  end

  # Single ASCII byte
  def tokenize_comment(<<h, rest::binary>>, acc) when h < 128 do
    tokenize_comment(rest, [h | acc])
  end

  # Non-ASCII - need to check codepoint for bidi/break
  def tokenize_comment(<<h::utf8, _rest::binary>>, _) when bidi(h) do
    {:error, {:comment_invalid_bidi, h}}
  end

  def tokenize_comment(<<h::utf8, _rest::binary>>, _) when break(h) do
    {:error, {:comment_invalid_linebreak, h}}
  end

  def tokenize_comment(<<h::utf8, rest::binary>>, acc) do
    # h is the codepoint, add directly to charlist
    tokenize_comment(rest, [h | acc])
  end

  def tokenize_comment(<<>>, acc) do
    {<<>>, :lists.reverse(acc)}
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
