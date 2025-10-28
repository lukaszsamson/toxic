defmodule Toxic.Comment do
  @moduledoc false
  import Toxic.CharacterClassifier

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
end
