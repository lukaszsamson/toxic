defmodule Toxic.Unescape do
  import Toxic.CharacterClassifier, only: [is_hex: 1]

  def unescape_tokens(tokens) do
    try do
      map_fun = &unescape_map/1

      {:ok, Enum.map(tokens, fn token -> unescape_token(token, map_fun) end)}
    catch
      {:error, _reason, _token} = error -> error
    end
  end

  defp unescape_token(token, map_fun) when is_list(token) do
    unescape_chars(Toxic.Util.characters_to_binary(token), map_fun)
  end

  defp unescape_token(token, map_fun) when is_binary(token) do
    unescape_chars(token, map_fun)
  end

  defp unescape_token(other, _map_fun), do: other

  defp unescape_chars(string, map_fun) do
    unescape_chars(string, map_fun, <<>>)
  end

  defp unescape_chars(<<?\\, ?x, rest::binary>>, map_fun, acc) do
    case map_fun.(:hex) do
      true -> unescape_hex(rest, map_fun, acc)
      false -> unescape_chars(rest, map_fun, <<acc::binary, ?\\, ?x>>)
    end
  end

  defp unescape_chars(<<?\\, ?u, rest::binary>>, map_fun, acc) do
    # TODO: no coverage
    case map_fun.(:unicode) do
      true -> unescape_unicode(rest, map_fun, acc)
      false -> unescape_chars(rest, map_fun, <<acc::binary, ?\\, ?u>>)
    end
  end

  defp unescape_chars(<<?\\, ?\n, rest::binary>>, map_fun, acc) do
    case map_fun.(:newline) do
      true -> unescape_chars(rest, map_fun, acc)
      false -> unescape_chars(rest, map_fun, <<acc::binary, ?\\, ?\n>>)
    end
  end

  defp unescape_chars(<<?\\, ?\r, ?\n, rest::binary>>, map_fun, acc) do
    case map_fun.(:newline) do
      true -> unescape_chars(rest, map_fun, acc)
      false -> unescape_chars(rest, map_fun, <<acc::binary, ?\\, ?\r, ?\n>>)
    end
  end

  defp unescape_chars(<<?\\, escaped, rest::binary>>, map_fun, acc) do
    case map_fun.(escaped) do
      false -> unescape_chars(rest, map_fun, <<acc::binary, ?\\, escaped>>)
      other -> unescape_chars(rest, map_fun, <<acc::binary, other>>)
    end
  end

  defp unescape_chars(<<char, rest::binary>>, map_fun, acc) do
    unescape_chars(rest, map_fun, <<acc::binary, char>>)
  end

  defp unescape_chars(<<>>, _map_fun, acc), do: acc

  defp unescape_hex(<<a, b, rest::binary>>, map_fun, acc) when is_hex(a) and is_hex(b) do
    # TODO: no coverage
    bytes = :erlang.list_to_integer([a, b], 16)
    unescape_chars(rest, map_fun, <<acc::binary, bytes>>)
  end

  # Support deprecated single-hex format for compatibility with Elixir
  defp unescape_hex(<<a, rest::binary>>, map_fun, acc) when is_hex(a) do
    IO.warn(
      "\\xH inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a], acc, 16)
  end

  # Support deprecated \x{H*} formats for compatibility with Elixir
  defp unescape_hex(<<?{, a, ?}, rest::binary>>, map_fun, acc) when is_hex(a) do
    IO.warn(
      "\\x{H*} inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a], acc, 16)
  end

  defp unescape_hex(<<?{, a, b, ?}, rest::binary>>, map_fun, acc) when is_hex(a) and is_hex(b) do
    IO.warn(
      "\\x{H*} inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a, b], acc, 16)
  end

  defp unescape_hex(<<?{, a, b, c, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) do
    IO.warn(
      "\\x{H*} inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a, b, c], acc, 16)
  end

  defp unescape_hex(<<?{, a, b, c, d, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) do
    IO.warn(
      "\\x{H*} inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a, b, c, d], acc, 16)
  end

  defp unescape_hex(<<?{, a, b, c, d, e, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) and is_hex(e) do
    IO.warn(
      "\\x{H*} inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a, b, c, d, e], acc, 16)
  end

  defp unescape_hex(<<?{, a, b, c, d, e, f, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) and is_hex(e) and is_hex(f) do
    IO.warn(
      "\\x{H*} inside strings/sigils/chars is deprecated, please use \\xHH (byte) or \\uHHHH (code point) instead"
    )

    append_codepoint(rest, map_fun, [a, b, c, d, e, f], acc, 16)
  end

  defp unescape_hex(<<_::binary>>, _map_fun, _acc) do
    throw(
      {:error, ~c"invalid hex escape character, expected \\xHH where H is a hexadecimal digit",
       ~c"\\x"}
    )
  end

  defp unescape_unicode(<<?{, a, ?}, rest::binary>>, map_fun, acc) when is_hex(a) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a], acc, 16)
  end

  defp unescape_unicode(<<?{, a, b, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a, b], acc, 16)
  end

  defp unescape_unicode(<<?{, a, b, c, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a, b, c], acc, 16)
  end

  defp unescape_unicode(<<?{, a, b, c, d, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a, b, c, d], acc, 16)
  end

  defp unescape_unicode(<<?{, a, b, c, d, e, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) and is_hex(e) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a, b, c, d, e], acc, 16)
  end

  defp unescape_unicode(<<?{, a, b, c, d, e, f, ?}, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) and is_hex(e) and is_hex(f) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a, b, c, d, e, f], acc, 16)
  end

  defp unescape_unicode(<<a, b, c, d, rest::binary>>, map_fun, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) do
    # TODO: no coverage
    append_codepoint(rest, map_fun, [a, b, c, d], acc, 16)
  end

  defp unescape_unicode(<<_::binary>>, _map_fun, _acc) do
    throw(
      {:error,
       ~c"invalid Unicode escape character, expected \\uHHHH or \\u{H*} where H is a hexadecimal digit",
       ~c"\\u"}
    )
  end

  defp append_codepoint(rest, map_fun, list, acc, base) do
    codepoint = :erlang.list_to_integer(list, base)

    try do
      unescape_chars(rest, map_fun, <<acc::binary, codepoint::utf8>>)
    rescue
      ArgumentError ->
        throw({:error, ~c"invalid or reserved Unicode code point \\u{" ++ list ++ ~c"}", ~c"\\u"})
    end
  end

  def unescape_map(:newline), do: true
  # TODO: no coverage
  def unescape_map(:unicode), do: true
  def unescape_map(:hex), do: true
  def unescape_map(?0), do: 0
  def unescape_map(?a), do: 7
  # TODO: no coverage
  def unescape_map(?b), do: ?\b
  # TODO: no coverage
  def unescape_map(?d), do: ?\d
  # TODO: no coverage
  def unescape_map(?e), do: ?\e
  # TODO: no coverage
  def unescape_map(?f), do: ?\f
  def unescape_map(?n), do: ?\n
  def unescape_map(?r), do: ?\r
  # TODO: no coverage
  def unescape_map(?s), do: ?\s
  def unescape_map(?t), do: ?\t
  # TODO: no coverage
  def unescape_map(?v), do: ?\v
  def unescape_map(other), do: other
end
