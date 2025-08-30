defmodule Toxic.Alias do
  import Toxic.Util
  import Toxic.Token

  def tokenize_alias(rest, line, column, unencoded, atom, length, ascii?, special, scope, _tokens) do
    if not ascii? or special != [] do
      {:error, :invalid_character}
      # Invalid = hd([C || C <- Unencoded, (C < $A) or (C > 127)]),
      # Reason = {?LOC(Line, Column), invalid_character_error("alias (only ASCII characters, without punctuation, are allowed)", Invalid), Unencoded},
      # error(Reason, Unencoded ++ Rest, Scope, Tokens);
    else
      aliases_token = {:alias, meta(line, column, length, unencoded), atom}
      emit(aliases_token, rest, line, column + length, scope)
    end
  end
end
