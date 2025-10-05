defmodule Toxic.Alias do
  import Toxic.Util
  import Toxic.Token

  def tokenize_alias(rest, line, column, unencoded, atom, length, ascii?, special, scope, _tokens) do
    if not ascii? or special != [] do
      invalid_char = hd(for c <- unencoded, c < ?A or c > 127, do: c)
      # Build message that will match when converted to binary
      char_hex = String.upcase(Integer.to_string(invalid_char, 16))
      char_hex_padded = String.pad_leading(char_hex, 4, "0")

      message =
        ~c"invalid character \"" ++
          [invalid_char] ++
          ~c"\" (code point U+" ++
          String.to_charlist(char_hex_padded) ++
          ~c") in " ++
          ~c"alias (only ASCII characters, without punctuation, are allowed)" ++
          ~c": "

      reason = {[line: line, column: column], message, unencoded}
      # Keep legacy reason to leverage Driver bridge, but also provide structured form
      err = %Toxic.Error{
        code: :alias_invalid_character,
        domain: :alias,
        token_display: unencoded,
        details: %{line: line, column: column, message_iolist: message}
      }
      {:error, err}
    else
      aliases_token = alias_token(meta(line, column, length, unencoded), atom)
      emit(aliases_token, rest, line, column + length, scope)
    end
  end
end
