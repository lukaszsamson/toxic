defmodule Toxic.Identifier do
  import Toxic.Scope
  import Toxic.Util
  import Toxic.Token

  def check_call_identifier(line, column, length, info, atom, [?( | _]) do
    {:paren_identifier, meta(line, column, length, info), atom}
  end

  def check_call_identifier(line, column, length, info, atom, [?[ | _]) do
    {:bracket_identifier, meta(line, column, length, info), atom}
  end

  def check_call_identifier(line, column, length, info, atom, _rest) do
    {:identifier, meta(line, column, length, info), atom}
  end

  def tokenize_identifier(string, line, column, scope, maybe_keyword?) do
    scope(identifier_tokenizer: identifier_tokenizer) = scope

    case identifier_tokenizer.tokenize(string) do
      {kind, acc, rest, length, ascii, special} ->
        keyword = maybe_keyword? and maybe_keyword?(rest)

        case keyword_or_unsafe_to_atom(keyword, acc, line, column, scope) do
          {:keyword, atom, type} ->
            {keyword, atom, type, rest, length}

          {:ok, atom} ->
            {kind, acc, atom, rest, length, ascii, special}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, {:mixed_script, Wrong, {Prefix, Suffix}}} ->
        {:error, :mixed_script}

      # Wrongcolumn = column + length(Wrong) - 1,
      # case suggest_simpler_unexpected_token_in_error(Wrong, line, Wrongcolumn, scope) of
      #   no_suggestion ->
      #     # we append a pointer to more info if we aren't appending a suggestion
      #     MoreInfo = "\nSee https://hexdocs.pm/elixir/unicode-syntax.html for more information.",
      #     {error, {?LOC(line, column), {Prefix, Suffix ++ MoreInfo}, Wrong}};

      #   {_, {Location, _, SuggestionMessage}} = _SuggestionError ->
      #     {error, {Location, {Prefix, Suffix ++ SuggestionMessage}, Wrong}}
      # end

      {:error, {:unexpected_token, wrong}} ->
        {:unexpected_token, length(wrong)}

      # Wrongcolumn = column + length(Wrong) - 1,
      # case suggest_simpler_unexpected_token_in_error(Wrong, line, Wrongcolumn, scope) of
      #   no_suggestion ->
      #     [T | _] = lists:reverse(Wrong),
      #     case suggest_simpler_unexpected_token_in_error([T], line, Wrongcolumn, scope) of
      #       no_suggestion -> {unexpected_token, length(Wrong)};
      #       SuggestionError -> SuggestionError
      #     end;

      #   SuggestionError ->
      #     SuggestionError
      # end;

      {:error, :empty} ->
        :empty
    end
  end

  defp maybe_keyword?([]), do: true
  defp maybe_keyword?([?:, ?: | _]), do: true
  defp maybe_keyword?([?: | _]), do: false
  defp maybe_keyword?(_), do: true

  defp keyword_or_unsafe_to_atom(true, ~c"fn", _line, _column, _scope),
    do: {:keyword, :fn, :terminator}

  defp keyword_or_unsafe_to_atom(true, ~c"do", _line, _column, _scope),
    do: {:keyword, :do, :terminator}

  defp keyword_or_unsafe_to_atom(true, ~c"end", _line, _column, _scope),
    do: {:keyword, :end, :terminator}

  defp keyword_or_unsafe_to_atom(true, ~c"true", _line, _column, _scope),
    do: {:keyword, true, :token}

  defp keyword_or_unsafe_to_atom(true, ~c"false", _line, _column, _scope),
    do: {:keyword, false, :token}

  defp keyword_or_unsafe_to_atom(true, ~c"nil", _line, _column, _scope),
    do: {:keyword, nil, :token}

  defp keyword_or_unsafe_to_atom(true, ~c"not", _line, _column, _scope),
    do: {:keyword, :not, :unary_op}

  defp keyword_or_unsafe_to_atom(true, ~c"and", _line, _column, _scope),
    do: {:keyword, :and, :and_op}

  defp keyword_or_unsafe_to_atom(true, ~c"or", _line, _column, _scope),
    do: {:keyword, :or, :or_op}

  defp keyword_or_unsafe_to_atom(true, ~c"when", _line, _column, _scope),
    do: {:keyword, :when, :when_op}

  defp keyword_or_unsafe_to_atom(true, ~c"in", _line, _column, _scope),
    do: {:keyword, :in, :in_op}

  defp keyword_or_unsafe_to_atom(true, ~c"after", _line, _column, _scope),
    do: {:keyword, :after, :block}

  defp keyword_or_unsafe_to_atom(true, ~c"else", _line, _column, _scope),
    do: {:keyword, :else, :block}

  defp keyword_or_unsafe_to_atom(true, ~c"catch", _line, _column, _scope),
    do: {:keyword, :catch, :block}

  defp keyword_or_unsafe_to_atom(true, ~c"rescue", _line, _column, _scope),
    do: {:keyword, :rescue, :block}

  defp keyword_or_unsafe_to_atom(_, part, line, column, scope) do
    unsafe_to_atom(part, line, column, scope)
  end
end
