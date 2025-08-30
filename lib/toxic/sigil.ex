defmodule Toxic.Sigil do
  import Toxic.CharacterClassifier
  import Toxic.Token

  def tokenize_sigil([?~ | t], line, column, scope, tokens) do
    case tokenize_sigil_name(t, [], line, column + 1, scope, tokens) do
      {:ok, name, rest, new_line, new_column, new_scope, new_tokens} ->
        tokenize_sigil_contents(rest, name, new_line, new_column, new_scope, new_tokens)

      {:error, reason} ->
        # reason = {make_meta_len(line, column, 1, nil, scope), Message, Token}
        # error(Reason, T, scope, tokens)
        {:error, reason}
    end
  end

  # # A one-letter sigil is ok both as upcase as well as downcase.
  def tokenize_sigil_name([s | t], [], line, column, scope, tokens) when is_downcase(s) do
    tokenize_lower_sigil_name(t, [s], line, column + 1, scope, tokens)
  end

  def tokenize_sigil_name([s | t], [], line, column, scope, tokens) when is_upcase(s) do
    tokenize_upper_sigil_name(t, [s], line, column + 1, scope, tokens)
  end

  def tokenize_lower_sigil_name(
        [s | _t] = _original,
        [_ | _] = _name_acc,
        _line,
        _column,
        _scope,
        _tokens
      )
      when is_downcase(s) do
    # sigil_name = Enum.reverse(name_acc) ++ original
    # {:error, sigil_name_error(), [?~] ++ sigil_name}
    {:error, :invalid_sigil_name}
  end

  def tokenize_lower_sigil_name(t, name_acc, line, column, scope, tokens) do
    {:ok, Enum.reverse(name_acc), t, line, column, scope, tokens}
  end

  # If we have an uppercase letter, we keep tokenizing the name.
  # A digit is allowed but an uppercase letter or digit must proceed it.
  def tokenize_upper_sigil_name([s | t], name_acc, line, column, scope, tokens)
      when is_upcase(s) or is_digit(s) do
    tokenize_upper_sigil_name(t, [s | name_acc], line, column + 1, scope, tokens)
  end

  # With a lowercase letter and a non-empty name_acc we return an error.
  def tokenize_upper_sigil_name(
        [s | _t] = _original,
        [_ | _] = _name_acc,
        _line,
        _column,
        _scope,
        _tokens
      )
      when is_downcase(s) do
    # sigil_name = Enum.reverse(name_acc) ++ original
    # {:error,  sigil_name_error(), [?~] ++ sigil_name}
    {:error, :invalid_sigil_name}
  end

  # We finished the letters, so the name is over.
  def tokenize_upper_sigil_name(t, name_acc, line, column, scope, tokens) do
    {:ok, Enum.reverse(name_acc), t, line, column, scope, tokens}
  end

  # # sigil_name_error() ->
  # #   "invalid sigil name, it should be either a one-letter lowercase letter or an " ++
  # #   "uppercase letter optionally followed by uppercase letters and digits, got: ".

  # def tokenize_sigil_contents([H, H, H | T] = original, [S | _] = sigil_name, line, column, scope, tokens)
  #     when is_quote(h) do
  #   case extract_heredoc_header(t) do
  #     {ok, Headerless} ->
  #       sigil_atom = list_to_atom("sigil_" ++ sigil_name)
  #       start_column = column - length(sigil_name) - 1
  #       start_token = {sigil_start, make_meta(line, start_column, line, column + 3, nil, scope), sigil_atom, <<H,H,H>>}
  #       % Switch to interpolation streaming; pass closing delimiter [H,H,H]
  #       % Store sigil info in interpolation payload: {sigil_info, sigil_atom, Interpol?, StartDelim}
  #       Interp = {sigil_info, sigil_atom, ?is_downcase(S), <<H,H,H>>}
  #       {switch_to_interp, start_token, Headerless, line + 1, 1, scope, sigil, [H, H, H], Interp}
  #     {error, Message} ->
  #       error({make_meta_len(line, column - 1 - length(sigil_name), 1, nil, scope), "heredoc allows only whitespace characters followed by a new line after opening ", Message}, [$~] ++ sigil_name ++ original, scope, tokens)
  #   end
  # end

  def tokenize_sigil_contents(
        [h | t] = _original,
        [s | _] = sigil_name,
        line,
        column,
        scope,
        _tokens
      )
      when is_sigil(h) do
    sigil_atom = List.to_atom(~c"sigil_" ++ sigil_name)
    start_column = column - length(sigil_name) - 1

    start_token =
      {:sigil_start, meta(line, start_column, line, column + 1, nil), sigil_atom, <<h>>}

    interp = {:sigil_info, sigil_atom, is_downcase(s), <<h>>}

    {:switch_to_interp, start_token, t, line, column + 1, scope, :sigil, sigil_terminator(h),
     interp}
  end

  # def tokenize_sigil_contents([H | _] = original, sigil_name, line, column, scope, tokens) do
  #   {:error, :invalid_sigil_delimiter}
  #   # MessageString =
  #   #   "\"~ts\" (column ~p, code point U+~4.16.0B). The available delimiters are: "
  #   #   "//, ||, \"\", '', (), [], {}, <>"
  #   # Message = io_lib:format(MessageString, [[H], column, H])
  #   # Errorcolumn = column - 1 - length(sigil_name)
  #   # error({make_meta_len(line, Errorcolumn, 1, nil, scope), "invalid sigil delimiter: ", Message}, [$~] ++ sigil_name ++ original, scope, tokens)
  # end

  # # Incomplete sigil.
  # def tokenize_sigil_contents([], _sigil_name, line, column, scope, tokens) do
  #   # Yield directly - incomplete sigil case
  #   yield([], line, column, scope, tokens)
  # end

  defp sigil_terminator(?(), do: ?)
  defp sigil_terminator(?[), do: ?]
  defp sigil_terminator(?{), do: ?}
  defp sigil_terminator(?<), do: ?>
  defp sigil_terminator(other), do: other
end
