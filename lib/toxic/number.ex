defmodule Toxic.Number do
  import Toxic.CharacterClassifier

  def tokenize_hex([h | t], acc, length) when is_hex(h) do
    tokenize_hex(t, [h | acc], length + 1)
  end

  def tokenize_hex([?_, h | t], acc, length) when is_hex(h) do
    tokenize_hex(t, [h, ?_ | acc], length + 2)
  end

  def tokenize_hex(rest, acc, length) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number, 16), [?0, ?x | original], length}
  end

  def tokenize_octal([h | t], acc, length) when is_octal(h) do
    tokenize_octal(t, [h | acc], length + 1)
  end

  def tokenize_octal([?_, h | t], acc, length) when is_octal(h) do
    tokenize_octal(t, [h, ?_ | acc], length + 2)
  end

  def tokenize_octal(rest, acc, length) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number, 8), [?0, ?o | original], length}
  end

  def tokenize_bin([h | t], acc, length) when is_bin(h) do
    tokenize_bin(t, [h | acc], length + 1)
  end

  def tokenize_bin([?_, h | t], acc, length) when is_bin(h) do
    tokenize_bin(t, [h, ?_ | acc], length + 2)
  end

  def tokenize_bin(rest, acc, length) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number, 2), [?0, ?b | original], length}
  end

  # Check if we have a point followed by a number;
  def tokenize_number([?., h | t], acc, length, false) when is_digit(h) do
    tokenize_number(t, [h, ?. | acc], length + 2, true)
  end

  # Check if we have an underscore followed by a number;
  def tokenize_number([?_, h | t], acc, length, bool) when is_digit(h) do
    tokenize_number(t, [h, ?_ | acc], length + 2, bool)
  end

  # Check if we have e- followed by numbers (valid only for floats);
  def tokenize_number([e, s, h | t], acc, length, true)
      when e in [?E, ?e] and is_digit(h) and s in [?+, ?-] do
    tokenize_number(t, [h, s, e | acc], length + 3, true)
  end

  # Check if we have e followed by numbers (valid only for floats);
  def tokenize_number([e, h | t], acc, length, true)
      when e in [?E, ?e] and is_digit(h) do
    tokenize_number(t, [h, e | acc], length + 2, true)
  end

  # Finally just numbers.
  def tokenize_number([h | t], acc, length, bool) when is_digit(h) do
    tokenize_number(t, [h | acc], length + 1, bool)
  end

  # Cast to float...
  def tokenize_number(rest, acc, length, true) do
    try do
      {number, original} = reverse_number(acc, [], [])
      {rest, List.to_float(number), original, length}
    rescue
      ArgumentError ->
        original = Enum.reverse(acc)
        {:error, ~c"invalid float number ", original}
    end
  end

  # Or integer.
  def tokenize_number(rest, acc, length, false) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number), original, length}
  end

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
