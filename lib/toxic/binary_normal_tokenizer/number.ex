defmodule Toxic.BinaryNormalTokenizer.Number do
  @moduledoc false
  import Toxic.CharacterClassifier

  def tokenize_hex(<<h, rest::binary>>, acc, length) when is_hex(h) do
    tokenize_hex(rest, [acc, h], length + 1)
  end

  def tokenize_hex(<<?_, h, rest::binary>>, acc, length) when is_hex(h) do
    tokenize_hex(rest, [acc, ?_, h], length + 2)
  end

  def tokenize_hex(rest, acc, length) when is_binary(rest) do
    original = IO.iodata_to_binary(acc)
    number_str = String.replace(original, "_", "")
    number = String.to_integer(number_str, 16)
    # Return charlist for original representation (compatibility)
    {rest, number, [?0, ?x | String.to_charlist(original)], length}
  end

  def tokenize_octal(<<h, rest::binary>>, acc, length) when is_octal(h) do
    tokenize_octal(rest, [acc, h], length + 1)
  end

  def tokenize_octal(<<?_, h, rest::binary>>, acc, length) when is_octal(h) do
    tokenize_octal(rest, [acc, ?_, h], length + 2)
  end

  def tokenize_octal(rest, acc, length) when is_binary(rest) do
    original = IO.iodata_to_binary(acc)
    number_str = String.replace(original, "_", "")
    number = String.to_integer(number_str, 8)
    {rest, number, [?0, ?o | String.to_charlist(original)], length}
  end

  def tokenize_bin(<<h, rest::binary>>, acc, length) when is_bin(h) do
    tokenize_bin(rest, [acc, h], length + 1)
  end

  def tokenize_bin(<<?_, h, rest::binary>>, acc, length) when is_bin(h) do
    tokenize_bin(rest, [acc, ?_, h], length + 2)
  end

  def tokenize_bin(rest, acc, length) when is_binary(rest) do
    original = IO.iodata_to_binary(acc)
    number_str = String.replace(original, "_", "")
    number = String.to_integer(number_str, 2)
    {rest, number, [?0, ?b | String.to_charlist(original)], length}
  end

  # Check if we have a point followed by a number;
  def tokenize_number(<<?., h, rest::binary>>, acc, length, false) when is_digit(h) do
    tokenize_number(rest, [acc, ?., h], length + 2, true)
  end

  # Check if we have an underscore followed by a number;
  def tokenize_number(<<?_, h, rest::binary>>, acc, length, bool) when is_digit(h) do
    tokenize_number(rest, [acc, ?_, h], length + 2, bool)
  end

  # Check if we have e- followed by numbers (valid only for floats);
  def tokenize_number(<<e, s, h, rest::binary>>, acc, length, true)
      when e in [?E, ?e] and is_digit(h) and s in [?+, ?-] do
    tokenize_number(rest, [acc, e, s, h], length + 3, true)
  end

  # Check if we have e followed by numbers (valid only for floats);
  def tokenize_number(<<e, h, rest::binary>>, acc, length, true)
      when e in [?E, ?e] and is_digit(h) do
    tokenize_number(rest, [acc, e, h], length + 2, true)
  end

  # Finally just numbers.
  def tokenize_number(<<h, rest::binary>>, acc, length, bool) when is_digit(h) do
    tokenize_number(rest, [acc, h], length + 1, bool)
  end

  # Cast to float...
  def tokenize_number(rest, acc, length, true) when is_binary(rest) do
    original = IO.iodata_to_binary(acc)
    number_str = String.replace(original, "_", "")

    try do
      number = String.to_float(number_str)
      {rest, number, String.to_charlist(original), length}
    rescue
      ArgumentError ->
        {:error, ~c"invalid float number ", String.to_charlist(original)}
    end
  end

  # Or integer.
  def tokenize_number(rest, acc, length, false) when is_binary(rest) do
    original = IO.iodata_to_binary(acc)
    number_str = String.replace(original, "_", "")
    number = String.to_integer(number_str)
    {rest, number, String.to_charlist(original), length}
  end
end
