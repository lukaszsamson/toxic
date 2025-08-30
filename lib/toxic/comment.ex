defmodule Toxic.Comment do
  import Toxic.CharacterClassifier

  def tokenize_comment([?\r, ?\n | _] = rest, acc) do
    {rest, Enum.reverse(acc)}
  end

  def tokenize_comment([?\n | _] = rest, acc) do
    {rest, Enum.reverse(acc)}
  end

  def tokenize_comment([h | _rest], _) when bidi(h) do
    {:error, h}
  end

  def tokenize_comment([h | rest], acc) do
    tokenize_comment(rest, [h | acc])
  end

  def tokenize_comment([], acc) do
    {[], Enum.reverse(acc)}
  end
end
