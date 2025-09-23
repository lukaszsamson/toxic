defmodule Toxic.Util do
  import Toxic.CharacterClassifier, only: [is_horizontal_space: 1]
  import Toxic.Scope

  def strip_horizontal_space([h | t], counter) when is_horizontal_space(h) do
    strip_horizontal_space(t, counter + 1)
  end

  def strip_horizontal_space(t, counter), do: {t, counter}

  def no_token(rest, line, column, scope) do
    {nil, rest, line, column, scope}
  end

  def reset_eol(rest, line, column, scope) do
    {:reset_eol, rest, line, column, scope}
  end

  def increase_eol(rest, line, column, scope) do
    {:increase_eol, rest, line, column, scope}
  end

  def emit(token, rest, line, column, scope) do
    {{:token, token}, rest, line, column, scope}
  end

  def emit_with_eol(token, rest, line, column, scope) do
    {{:token_with_eol, token}, rest, line, column, scope}
  end

  def emit_op_identifier(token, rest, line, column, scope) do
    {{:dual_op_identifier, token}, rest, line, column, scope}
  end

  def multiple(events = [_ | _], rest, line, column, scope) do
    {events, rest, line, column, scope}
  end

  def previous_was_eol([{:",", {_, _, count}} | _]) when count > 0, do: count
  def previous_was_eol([{:";", {_, _, count}} | _]) when count > 0, do: count
  def previous_was_eol([{:eol, {_, _, count}} | _]) when count > 0, do: count
  def previous_was_eol(_), do: nil

  def previous_was_dot?([{:., _} | _]), do: true
  def previous_was_dot?(_), do: false

  def unsafe_to_atom(part, line, column, _scope)
      when (is_binary(part) and byte_size(part) > 255) or
             (is_list(part) and length(part) > 255) do
    part_as_charlist = if is_binary(part), do: String.to_charlist(part), else: part

    {:error,
     {[line: line, column: column], ~c"atom length must be less than system limit: ",
      part_as_charlist}}
  end

  # TODO: static_atoms_encoder

  # def unsafe_to_atom(part, line, column, #elixir_tokenizer{static_atoms_encoder=StaticAtomsEncoder}) when
  #     is_function(StaticAtomsEncoder) do
  #   Value = elixir_utils:characters_to_binary(part),
  #   case StaticAtomsEncoder(Value, [{line, line}, {column, column}]) of
  #     {ok, Term} ->
  #       {ok, Term};
  #     {error, Reason} when is_binary(Reason) ->
  #       {error, {?LOC(line, column), elixir_utils:characters_to_list(Reason) ++ ": ", elixir_utils:characters_to_list(part)}}
  #   end
  # end

  def unsafe_to_atom(list, line, column, scope(existing_atoms_only: true)) when is_list(list) do
    try do
      {:ok, List.to_existing_atom(list)}
    rescue
      ArgumentError ->
        {:error, {[line: line, column: column], "unsafe atom does not exist: ", list}}
    end
  end

  def unsafe_to_atom(list, _line, _column, _scope) when is_list(list) do
    {:ok, List.to_atom(list)}
  end

  def unescape_tokens(tokens, _line, _column, scope(unescape: true)) do
    case Toxic.Unescape.unescape_tokens(tokens) do
      {:ok, result} ->
        {:ok, result}

      {:error, _message, _token} ->
        {:error, :syntax_error}
        # {error, {?LOC(Line, Column), Message ++ ". Syntax error after: ", Token}}
    end
  end

  def unescape_tokens(tokens, _line, _column, scope(unescape: false)) do
    try do
      {:ok, tokens_to_binary(tokens)}
    rescue
      UnicodeConversionError ->
        # {error, {?LOC(Line, Column), "invalid encoding in tokens: ", toxic_utils:characters_to_list(Message)}}
        {:error, :invalid_encoding}
    end
  end

  defp tokens_to_binary(tokens) do
    for token <- tokens do
      if is_list(token), do: characters_to_binary(token), else: token
    end
  end

  def characters_to_binary(data) when is_binary(data), do: data

  def characters_to_binary(data) do
    case :unicode.characters_to_binary(data) do
      result when is_binary(result) -> result
      {:error, encoded, rest} -> conversion_error(:invalid, encoded, rest)
      {:incomplete, encoded, rest} -> conversion_error(:incomplete, encoded, rest)
    end
  end

  defp conversion_error(kind, encoded, rest) do
    raise UnicodeConversionError.exception(encoded: encoded, rest: rest, kind: kind)
  end
end
