defmodule Toxic.BinaryNormalTokenizer.Identifier do
  @moduledoc false
  import Toxic.Util
  import Toxic.Token

  def check_call_identifier(line, column, length, info, atom, <<?(, _::binary>>) do
    {:paren_identifier, meta(line, column, length, info), atom}
  end

  def check_call_identifier(line, column, length, info, atom, <<?[, _::binary>>) do
    {:bracket_identifier, meta(line, column, length, info), atom}
  end

  def check_call_identifier(line, column, length, info, atom, _rest) do
    {:identifier, meta(line, column, length, info), atom}
  end

  def tokenize_identifier(string, line, column, scope, maybe_keyword?) when is_binary(string) do
    # Use our binary-based tokenizer
    case Toxic.String.Tokenizer.tokenize(string) do
      {kind, acc, rest, length, ascii, special} ->
        keyword = maybe_keyword? and maybe_keyword?(rest)

        case keyword_or_unsafe_to_atom(keyword, acc, line, column, scope) do
          {:keyword, atom, type} ->
            {:keyword, atom, type, rest, length}

          {:ok, atom} ->
            # acc is binary from String.Tokenizer
            # Convert to charlist for compatibility with existing token format
            # Use fast path for ASCII-only identifiers
            acc_charlist =
              if ascii do
                :binary.bin_to_list(acc)
              else
                :unicode.characters_to_list(acc)
              end

            {kind, acc_charlist, atom, rest, length, ascii, special}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, {:mixed_script, wrong, {prefix, suffix}}} ->
        # wrong is now binary from refactored tokenizer
        wrong_charlist = String.to_charlist(wrong)
        wrong_column = column + String.length(wrong) - 1

        has_suggestion? =
          case suggest_simpler_unexpected_token_in_error(wrong, line, wrong_column, scope) do
            {:error, %Toxic.Error{}} -> true
            :no_suggestion -> false
          end

        error_column = if has_suggestion?, do: wrong_column, else: column

        message_suffix =
          suffix <>
            "\nSee https://hexdocs.pm/elixir/unicode-syntax.html for more information."

        err = %Toxic.Error{
          code: :identifier_mixed_script,
          domain: :identifier,
          token_display: wrong_charlist,
          details: %{
            line: line,
            column: error_column,
            message_prefix: prefix,
            message_suffix: String.to_charlist(message_suffix)
          }
        }

        {:error, err}

      {:error, {:unexpected_token, wrong}} ->
        # wrong is now binary
        wrong_column = column + String.length(wrong) - 1

        case suggest_simpler_unexpected_token_in_error(wrong, line, wrong_column, scope) do
          {:error, reason} ->
            {:error, reason}

          :no_suggestion ->
            # Get last grapheme
            case String.last(wrong) do
              nil ->
                {:unexpected_token, String.length(wrong)}

              last ->
                case suggest_simpler_unexpected_token_in_error(last, line, wrong_column, scope) do
                  {:error, reason} ->
                    {:error, reason}

                  :no_suggestion ->
                    {:unexpected_token, String.length(wrong)}
                end
            end
        end

      {:error, :empty} ->
        :empty
    end
  end

  defp maybe_keyword?(<<>>), do: true
  defp maybe_keyword?(<<?:, ?:, _::binary>>), do: true
  defp maybe_keyword?(<<?:, _::binary>>), do: false
  defp maybe_keyword?(_), do: true

  # Binary keyword matching
  defp keyword_or_unsafe_to_atom(true, "fn", _line, _column, _scope),
    do: {:keyword, :fn, :terminator}

  defp keyword_or_unsafe_to_atom(true, "do", _line, _column, _scope),
    do: {:keyword, :do, :terminator}

  defp keyword_or_unsafe_to_atom(true, "end", _line, _column, _scope),
    do: {:keyword, :end, :terminator}

  defp keyword_or_unsafe_to_atom(true, "true", _line, _column, _scope),
    do: {:keyword, true, :token}

  defp keyword_or_unsafe_to_atom(true, "false", _line, _column, _scope),
    do: {:keyword, false, :token}

  defp keyword_or_unsafe_to_atom(true, "nil", _line, _column, _scope),
    do: {:keyword, nil, :token}

  defp keyword_or_unsafe_to_atom(true, "not", _line, _column, _scope),
    do: {:keyword, :not, :unary_op}

  defp keyword_or_unsafe_to_atom(true, "and", _line, _column, _scope),
    do: {:keyword, :and, :and_op}

  defp keyword_or_unsafe_to_atom(true, "or", _line, _column, _scope),
    do: {:keyword, :or, :or_op}

  defp keyword_or_unsafe_to_atom(true, "when", _line, _column, _scope),
    do: {:keyword, :when, :when_op}

  defp keyword_or_unsafe_to_atom(true, "in", _line, _column, _scope),
    do: {:keyword, :in, :in_op}

  defp keyword_or_unsafe_to_atom(true, "after", _line, _column, _scope),
    do: {:keyword, :after, :block}

  defp keyword_or_unsafe_to_atom(true, "else", _line, _column, _scope),
    do: {:keyword, :else, :block}

  defp keyword_or_unsafe_to_atom(true, "catch", _line, _column, _scope),
    do: {:keyword, :catch, :block}

  defp keyword_or_unsafe_to_atom(true, "rescue", _line, _column, _scope),
    do: {:keyword, :rescue, :block}

  defp keyword_or_unsafe_to_atom(_, part, line, column, scope) when is_binary(part) do
    # Convert binary to charlist for unsafe_to_atom (compatibility)
    unsafe_to_atom(String.to_charlist(part), line, column, scope)
  end

  defp suggest_simpler_unexpected_token_in_error(wrong, line, wrong_column, _scope) when is_binary(wrong) do
    wrong_charlist = String.to_charlist(wrong)
    nfkc = :unicode.characters_to_nfkc_list(wrong_charlist)

    case Toxic.String.Tokenizer.tokenize(IO.iodata_to_binary(nfkc)) do
      {:error, _reason} ->
        confusable = String.Tokenizer.Security.confusable_skeleton(wrong_charlist)

        case Toxic.String.Tokenizer.tokenize(IO.iodata_to_binary(confusable)) do
          {_, simpler, _, _, _, _} ->
            simpler_charlist = String.to_charlist(simpler)
            message =
              suggest_change(
                ~c"Codepoint failed identifier tokenization, but a simpler form was found.",
                wrong_charlist,
                ~c"You could write the above in a similar way that is accepted by Elixir:",
                simpler_charlist,
                ~c"See https://hexdocs.pm/elixir/unicode-syntax.html for more information."
              )

            {:error,
             %Toxic.Error{
               code: :identifier_unexpected_token,
               domain: :identifier,
               token_display: message,
               details: %{line: line, column: wrong_column}
             }}

          _other ->
            :no_suggestion
        end

      {_, nfkc_str, _, _, _, _} ->
        nfkc_chars = String.to_charlist(nfkc_str)
        message =
          suggest_change(
            ~c"Elixir expects unquoted Unicode atoms, variables, and calls to use allowed codepoints and to be in NFC form.",
            wrong_charlist,
            ~c"You could write the above in a compatible format that is accepted by Elixir:",
            nfkc_chars,
            ~c"See https://hexdocs.pm/elixir/unicode-syntax.html for more information."
          )

        {:error,
         %Toxic.Error{
           code: :identifier_unexpected_token,
           domain: :identifier,
           token_display: message,
           details: %{line: line, column: wrong_column}
         }}
    end
  end

  defp suggest_change(intro, wrong_form, hint, hinted_form, ending) do
    wrong_codepoints = list_to_codepoint_hex(wrong_form)
    hinted_codepoints = list_to_codepoint_hex(hinted_form)

    :io_lib.format(
      "~ts\n\nGot:\n\n    \"~ts\" (code points~ts)\n\nHint: ~ts\n\n    \"~ts\" (code points~ts)\n\n~ts",
      [intro, wrong_form, wrong_codepoints, hint, hinted_form, hinted_codepoints, ending]
    )
  end

  defp list_to_codepoint_hex(list) do
    Enum.map(list, fn codepoint -> :io_lib.format(" 0x~5.16.0B", [codepoint]) end)
  end
end
