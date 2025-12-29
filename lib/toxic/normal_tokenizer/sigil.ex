defmodule Toxic.NormalTokenizer.Sigil do
  @moduledoc false
  import Toxic.CharacterClassifier
  import Toxic.Token
  import Toxic.Scope
  alias Toxic.NormalTokenizer

  def tokenize_sigil([?~ | t], line, column, scope, tokens) do
    case tokenize_sigil_name(t, [], line, column + 1, scope, tokens) do
      {:ok, name, rest, new_line, new_column, new_scope, new_tokens} ->
        tokenize_sigil_contents(rest, name, new_line, new_column, new_scope, new_tokens)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A one-letter sigil is ok both as upcase as well as downcase.
  def tokenize_sigil_name([s | t], [], line, column, scope, tokens) when is_downcase(s) do
    tokenize_lower_sigil_name(t, [s], line, column + 1, scope, tokens)
  end

  def tokenize_sigil_name([s | t], [], line, column, scope, tokens) when is_upcase(s) do
    tokenize_upper_sigil_name(t, [s], line, column + 1, scope, tokens)
  end

  def tokenize_lower_sigil_name(
        [s | _t] = original,
        [_ | _] = name_acc,
        line,
        column,
        _scope,
        _tokens
      )
      when is_downcase(s) do
    sigil_name = [?~ | Enum.reverse(name_acc, original)]
    # Error position should be at the start of the sigil (~)
    error_column = column - length(name_acc) - 1

    err = %Toxic.Error{
      code: :sigil_invalid_name,
      domain: :sigil,
      token_display: sigil_name,
      details: %{line: line, column: error_column}
    }

    {:error, err}
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
        [s | _t] = original,
        [_ | _] = name_acc,
        line,
        column,
        _scope,
        _tokens
      )
      when is_downcase(s) do
    sigil_name = [?~ | Enum.reverse(name_acc, original)]
    error_column = column - length(name_acc) - 1

    err = %Toxic.Error{
      code: :sigil_invalid_name,
      domain: :sigil,
      token_display: sigil_name,
      details: %{line: line, column: error_column}
    }

    {:error, err}
  end

  # We finished the letters, so the name is over.
  def tokenize_upper_sigil_name(t, name_acc, line, column, scope, tokens) do
    {:ok, Enum.reverse(name_acc), t, line, column, scope, tokens}
  end

  def tokenize_sigil_contents(
        [h, h, h | t] = _original,
        [s | _] = sigil_name,
        line,
        column,
        scope,
        _tokens
      )
      when is_quote(h) do
    case NormalTokenizer.String.extract_heredoc_header(t) do
      {:ok, headerless} ->
        start_column = column - length(sigil_name) - 1

        case Toxic.Util.unsafe_to_atom(~c"sigil_" ++ sigil_name, line, start_column, scope) do
          {:ok, sigil_atom} ->
            start_token =
              token(
                :sigil_start,
                meta(line, start_column, line, column + 3, nil),
                sigil_atom,
                <<h, h, h>>
              )

            scope(column: base_column) = scope

            {{:switch_to_interp, start_token, :sigil, is_downcase(s), [h, h, h]},
             [?\n | headerless], line + 1, base_column, scope}

          {:error, err} ->
            {:error, err}
        end

      :error ->
        error_column = column + 3

        err = %Toxic.Error{
          code: :heredoc_invalid_header,
          domain: :heredoc,
          token_display: [h, h, h],
          details: %{
            line: line,
            column: error_column,
            delim: [h, h, h],
            message_excludes_delim?: true
          }
        }

        {:error, err}
    end
  end

  def tokenize_sigil_contents(
        [h | t] = _original,
        [s | _] = sigil_name,
        line,
        column,
        scope,
        _tokens
      )
      when is_sigil(h) do
    start_column = column - length(sigil_name) - 1

    case Toxic.Util.unsafe_to_atom(~c"sigil_" ++ sigil_name, line, start_column, scope) do
      {:ok, sigil_atom} ->
        start_token =
          token(:sigil_start, meta(line, start_column, line, column + 1, nil), sigil_atom, <<h>>)

        {{:switch_to_interp, start_token, :sigil, is_downcase(s), sigil_terminator(h)}, t, line,
         column + 1, scope}

      {:error, err} ->
        {:error, err}
    end
  end

  def tokenize_sigil_contents([h | _] = _original, sigil_name, line, column, _scope, _tokens) do
    start_column = column - length(sigil_name) - 1
    char_hex = String.upcase(Integer.to_string(h, 16))
    char_hex_padded = String.pad_leading(char_hex, 4, "0")

    message_detail =
      ~c"\"" ++
        [h] ++
        ~c"\" (column " ++
        Integer.to_charlist(column) ++
        ~c", code point U+" ++
        String.to_charlist(char_hex_padded) ++
        ~c"). The available delimiters are: //, ||, \"\", '', (), [], {}, <>"

    token = message_detail

    err = %Toxic.Error{
      code: :sigil_invalid_delimiter,
      domain: :sigil,
      token_display: token,
      details: %{line: line, column: start_column}
    }

    {:error, err}
  end

  # Incomplete sigil.
  def tokenize_sigil_contents([], _sigil_name, line, column, scope, _tokens) do
    {nil, [], line, column, scope}
  end

  defp sigil_terminator(?(), do: ?)
  defp sigil_terminator(?[), do: ?]
  defp sigil_terminator(?{), do: ?}
  defp sigil_terminator(?<), do: ?>
  defp sigil_terminator(other), do: other

  def collect_modifiers(string, buffer \\ [])

  def collect_modifiers([h | t], buffer) when is_downcase(h) or is_upcase(h) or is_digit(h) do
    collect_modifiers(t, [h | buffer])
  end

  def collect_modifiers(rest, buffer) do
    {rest, Enum.reverse(buffer)}
  end
end
