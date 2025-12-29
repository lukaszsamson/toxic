defmodule Toxic.BinaryNormalTokenizer.Comment do
  @moduledoc false
  import Toxic.CharacterClassifier
  import Toxic.Scope

  def tokenize_comment(<<?\r, ?\n, _::binary>> = rest, acc) do
    {rest, IO.iodata_to_binary(acc)}
  end

  def tokenize_comment(<<?\n, _::binary>> = rest, acc) do
    {rest, IO.iodata_to_binary(acc)}
  end

  # ASCII fast path - single byte, check bidi/break after
  def tokenize_comment(<<h, rest::binary>>, acc) when h < 128 do
    tokenize_comment(rest, [acc, h])
  end

  # Non-ASCII - need to check codepoint for bidi/break
  def tokenize_comment(<<h::utf8, _rest::binary>>, _) when bidi(h) do
    {:error, {:comment_invalid_bidi, h}}
  end

  def tokenize_comment(<<h::utf8, _rest::binary>>, _) when break(h) do
    {:error, {:comment_invalid_linebreak, h}}
  end

  def tokenize_comment(<<h::utf8, rest::binary>>, acc) do
    tokenize_comment(rest, [acc | <<h::utf8>>])
  end

  def tokenize_comment(<<>>, acc) do
    {<<>>, IO.iodata_to_binary(acc)}
  end

  def preserve_comments(
        line,
        column,
        tokens,
        comment,
        rest,
        scope(preserve_comments: preserve_comments)
      )
      when is_function(preserve_comments, 5) do
    preserve_comments.(line, column, tokens, comment, rest)
  end

  def preserve_comments(_line, _column, _tokens, _comment, _rest, _scope) do
    :ok
  end
end
