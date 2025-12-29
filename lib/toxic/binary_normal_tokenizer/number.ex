defmodule Toxic.BinaryNormalTokenizer.Number do
  @moduledoc false
  import Toxic.CharacterClassifier

  # Hex: use charlist cons accumulation
  def tokenize_hex(<<h, rest::binary>>, acc, length) when is_hex(h) do
    tokenize_hex(rest, [h | acc], length + 1)
  end

  def tokenize_hex(<<?_, h, rest::binary>>, acc, length) when is_hex(h) do
    tokenize_hex(rest, [h, ?_ | acc], length + 2)
  end

  def tokenize_hex(rest, acc, length) when is_binary(rest) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number, 16), [?0, ?x | original], length}
  end

  # Octal
  def tokenize_octal(<<h, rest::binary>>, acc, length) when is_octal(h) do
    tokenize_octal(rest, [h | acc], length + 1)
  end

  def tokenize_octal(<<?_, h, rest::binary>>, acc, length) when is_octal(h) do
    tokenize_octal(rest, [h, ?_ | acc], length + 2)
  end

  def tokenize_octal(rest, acc, length) when is_binary(rest) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number, 8), [?0, ?o | original], length}
  end

  # Binary
  def tokenize_bin(<<h, rest::binary>>, acc, length) when is_bin(h) do
    tokenize_bin(rest, [h | acc], length + 1)
  end

  def tokenize_bin(<<?_, h, rest::binary>>, acc, length) when is_bin(h) do
    tokenize_bin(rest, [h, ?_ | acc], length + 2)
  end

  def tokenize_bin(rest, acc, length) when is_binary(rest) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number, 2), [?0, ?b | original], length}
  end

  # Check if we have a point followed by a number;
  def tokenize_number(<<?., h, rest::binary>>, acc, length, false) when is_digit(h) do
    tokenize_number(rest, [h, ?. | acc], length + 2, true)
  end

  # Check if we have an underscore followed by a number;
  def tokenize_number(<<?_, h, rest::binary>>, acc, length, bool) when is_digit(h) do
    tokenize_number(rest, [h, ?_ | acc], length + 2, bool)
  end

  # Check if we have e- followed by numbers (valid only for floats);
  def tokenize_number(<<e, s, h, rest::binary>>, acc, length, true)
      when e in [?E, ?e] and is_digit(h) and s in [?+, ?-] do
    tokenize_number(rest, [h, s, e | acc], length + 3, true)
  end

  # Check if we have e followed by numbers (valid only for floats);
  def tokenize_number(<<e, h, rest::binary>>, acc, length, true)
      when e in [?E, ?e] and is_digit(h) do
    tokenize_number(rest, [h, e | acc], length + 2, true)
  end

  # Finally just numbers.
  def tokenize_number(<<h, rest::binary>>, acc, length, bool) when is_digit(h) do
    tokenize_number(rest, [h | acc], length + 1, bool)
  end

  # Cast to float...
  def tokenize_number(rest, acc, length, true) when is_binary(rest) do
    try do
      {number, original} = reverse_number(acc, [], [])
      {rest, List.to_float(number), original, length}
    rescue
      ArgumentError ->
        original = :lists.reverse(acc)
        {:error, ~c"invalid float number ", original}
    end
  end

  # Or integer.
  def tokenize_number(rest, acc, length, false) when is_binary(rest) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number), original, length}
  end

  # Single pass: reverse list and strip underscores for number parsing
  defp reverse_number([?_ | t], number, original) do
    reverse_number(t, number, [?_ | original])
  end

  defp reverse_number([h | t], number, original) do
    reverse_number(t, [h | number], [h | original])
  end

  defp reverse_number([], number, original) do
    {number, original}
  end
end
