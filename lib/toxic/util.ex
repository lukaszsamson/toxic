defmodule Toxic.Util do
  @moduledoc false
  import Toxic.CharacterClassifier, only: [is_horizontal_space: 1]
  import Toxic.Scope

  # Charlist variant
  def strip_horizontal_space([h1, h2, h3, h4 | t], counter)
      when is_horizontal_space(h1) and is_horizontal_space(h2) and is_horizontal_space(h3) and
             is_horizontal_space(h4) do
    strip_horizontal_space(t, counter + 4)
  end

  def strip_horizontal_space([h1, h2 | t], counter)
      when is_horizontal_space(h1) and is_horizontal_space(h2) do
    strip_horizontal_space(t, counter + 2)
  end

  def strip_horizontal_space([h | t], counter) when is_horizontal_space(h) do
    strip_horizontal_space(t, counter + 1)
  end

  def strip_horizontal_space(t, counter), do: {t, counter}

  # Binary variant
  def strip_horizontal_space_bin(<<h, h, h, h, h, h, h, h, t::binary>>, counter)
      when is_horizontal_space(h) do
    strip_horizontal_space_bin(t, counter + 8)
  end

  def strip_horizontal_space_bin(<<h, h, h, h, t::binary>>, counter)
      when is_horizontal_space(h) do
    strip_horizontal_space_bin(t, counter + 4)
  end

  def strip_horizontal_space_bin(<<h, h, t::binary>>, counter) when is_horizontal_space(h) do
    strip_horizontal_space_bin(t, counter + 2)
  end

  def strip_horizontal_space_bin(<<h, t::binary>>, counter) when is_horizontal_space(h) do
    strip_horizontal_space_bin(t, counter + 1)
  end

  def strip_horizontal_space_bin(t, counter) when is_binary(t), do: {t, counter}

  defmacro no_token(rest, line, column, scope) do
    quote do
      {nil, unquote(rest), unquote(line), unquote(column), unquote(scope)}
    end
  end

  defmacro reset_eol(rest, line, column, scope) do
    quote do
      {:reset_eol, unquote(rest), unquote(line), unquote(column), unquote(scope)}
    end
  end

  defmacro increase_eol(rest, line, column, scope) do
    quote do
      {:increase_eol, unquote(rest), unquote(line), unquote(column), unquote(scope)}
    end
  end

  defmacro emit(token, rest, line, column, scope) do
    quote do
      {{:token, unquote(token)}, unquote(rest), unquote(line), unquote(column), unquote(scope)}
    end
  end

  defmacro emit_with_eol(token, rest, line, column, scope) do
    quote do
      {{:token_with_eol, unquote(token)}, unquote(rest), unquote(line), unquote(column),
       unquote(scope)}
    end
  end

  defmacro emit_op_identifier(token, rest, line, column, scope) do
    quote do
      {{:dual_op_identifier, unquote(token)}, unquote(rest), unquote(line), unquote(column),
       unquote(scope)}
    end
  end

  defmacro multiple(events, rest, line, column, scope) do
    quote do
      {unquote(events), unquote(rest), unquote(line), unquote(column), unquote(scope)}
    end
  end

  @type lookbehind :: {Toxic.token() | nil, boolean(), non_neg_integer()}

  def lookbehind_from_token(nil), do: {nil, false, 0}

  def lookbehind_from_token({kind, {_, _, count}, _} = token)
      when kind in [:eol, :";", :","] and is_integer(count) and count > 0 do
    {token, true, count}
  end

  def lookbehind_from_token(token), do: {token, false, 0}

  @compile {:inline,
            lookbehind_from_token: 1, prev_token: 1, previous_was_eol: 1, previous_was_dot?: 1}

  def prev_token({prev, _prev_was_eol, _prev_eol_count}), do: prev

  def previous_was_eol({_prev, true, count}) when is_integer(count) and count > 0, do: count
  def previous_was_eol(_), do: nil

  def previous_was_dot?({{:., _, _}, _, _}), do: true
  def previous_was_dot?(_), do: false

  def unsafe_to_atom(part, line, column, _scope)
      when (is_binary(part) and byte_size(part) > 255) or
             (is_list(part) and length(part) > 255) do
    try do
      part_list = characters_to_list(part)

      {:error,
       %Toxic.Error{
         code: :identifier_atom_length_limit,
         domain: :identifier,
         token_display: part_list,
         details: %{line: line, column: column}
       }}
    rescue
      e in UnicodeConversionError ->
        {:error,
         %Toxic.Error{
           code: :encoding_invalid,
           domain: :encoding,
           token_display: String.to_charlist(Exception.message(e)),
           details: %{line: line, column: column}
         }}
    end
  end

  def unsafe_to_atom(part, line, column, scope(static_atoms_encoder: encoder))
      when (is_list(part) or is_binary(part)) and is_function(encoder, 2) do
    encode_result =
      try do
        value_bin = characters_to_binary(part)
        value_list = characters_to_list(part)
        {:ok, value_bin, value_list}
      rescue
        e in UnicodeConversionError ->
          {:error, String.to_charlist(Exception.message(e))}
      end

    case encode_result do
      {:ok, value_bin, value_list} ->
        case encoder.(value_bin, line: line, column: column) do
          {:ok, term} ->
            {:ok, term}

          {:error, reason} when is_binary(reason) ->
            {:error,
             %Toxic.Error{
               code: :identifier_static_atoms_encoder_error,
               domain: :identifier,
               token_display: value_list,
               details: %{line: line, column: column, reason: String.to_charlist(reason)}
             }}

          other ->
            {:error,
             %Toxic.Error{
               code: :identifier_static_atoms_encoder_error,
               domain: :identifier,
               token_display: value_list,
               details: %{line: line, column: column, reason: String.to_charlist(inspect(other))}
             }}
        end

      {:error, message_list} ->
        {:error,
         %Toxic.Error{
           code: :encoding_invalid,
           domain: :encoding,
           token_display: message_list,
           details: %{line: line, column: column}
         }}
    end
  end

  def unsafe_to_atom(list, line, column, scope(existing_atoms_only: true)) when is_list(list) do
    try do
      {:ok, List.to_existing_atom(list)}
    rescue
      ArgumentError ->
        {:error,
         %Toxic.Error{
           code: :identifier_nonexistent_atom_when_existing_only,
           domain: :identifier,
           token_display: list,
           details: %{line: line, column: column}
         }}
    end
  end

  def unsafe_to_atom(list, _line, _column, _scope) when is_list(list) do
    {:ok, List.to_atom(list)}
  end

  # Binary-specific clauses - avoid charlist conversion for common path
  def unsafe_to_atom(bin, line, column, scope(existing_atoms_only: true)) when is_binary(bin) do
    try do
      {:ok, String.to_existing_atom(bin)}
    rescue
      ArgumentError ->
        {:error,
         %Toxic.Error{
           code: :identifier_nonexistent_atom_when_existing_only,
           domain: :identifier,
           token_display: :binary.bin_to_list(bin),
           details: %{line: line, column: column}
         }}
    end
  end

  def unsafe_to_atom(bin, _line, _column, _scope) when is_binary(bin) do
    {:ok, String.to_atom(bin)}
  end

  def characters_to_binary(data) when is_list(data) do
    case :unicode.characters_to_binary(data) do
      result when is_binary(result) -> result
      {:error, encoded, rest} -> conversion_error(:invalid, encoded, rest)
      {:incomplete, encoded, rest} -> conversion_error(:incomplete, encoded, rest)
    end
  end

  def characters_to_binary(data) when is_binary(data) do
    case :unicode.characters_to_binary(data) do
      result when is_binary(result) -> result
      {:error, encoded, rest} -> conversion_error(:invalid, encoded, rest)
      {:incomplete, encoded, rest} -> conversion_error(:incomplete, encoded, rest)
    end
  end

  def characters_to_list(data) when is_list(data) or is_binary(data) do
    case :unicode.characters_to_list(data) do
      result when is_list(result) -> result
      {:error, encoded, rest} -> conversion_error(:invalid, encoded, rest)
      {:incomplete, encoded, rest} -> conversion_error(:incomplete, encoded, rest)
    end
  end

  defp conversion_error(kind, encoded, rest) do
    raise UnicodeConversionError.exception(encoded: encoded, rest: rest, kind: kind)
  end
end
