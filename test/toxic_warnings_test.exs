defmodule ToxicWarningsTest do
  use ExUnit.Case

  defp tokenize_and_compare_warning(string, opts \\ []) do
    charlist = to_charlist(string)
    existing_atoms_only = Keyword.get(opts, :existing_atoms_only, false)

    # Get warnings from Elixir tokenizer
    {:ok, _line, _column, elixir_warnings, _tokens, _terminators} =
      :elixir_tokenizer.tokenize(charlist, 1, 1, existing_atoms_only: existing_atoms_only)

    # Use the new streaming API for Toxic
    stream =
      Toxic.new(string, 1, 1,
        elixir_compatibility: Keyword.get(opts, :must_match_elixir, true),
        preserve_comments: Keyword.get(opts, :preserve_comments, false),
        existing_atoms_only: existing_atoms_only,
        error_mode: :strict
      )

    # Collect all tokens and warnings
    {_tokens, final_stream} = collect_all_tokens(stream, [])
    {toxic_warnings, _stream} = Toxic.warnings(final_stream)

    # Compare warnings
    assert_fn = Keyword.get(opts, :assert, &default_assert/2)
    assert_fn.(elixir_warnings, toxic_warnings)
    :ok
  end

  defp default_assert(elixir_warnings, toxic_warnings) do
    # Normalize and compare warnings
    normalized_elixir = normalize_warnings(elixir_warnings)
    normalized_toxic = normalize_warnings(toxic_warnings)

    assert length(normalized_toxic) == length(normalized_elixir),
           "Warning count mismatch: toxic #{length(normalized_toxic)} vs elixir #{length(normalized_elixir)}"

    Enum.zip(normalized_elixir, normalized_toxic)
    |> Enum.each(fn {{elixir_pos, elixir_msg}, {toxic_pos, toxic_msg}} ->
      assert toxic_pos == elixir_pos,
             "Position mismatch: toxic #{inspect(toxic_pos)} vs elixir #{inspect(elixir_pos)}"

      assert toxic_msg == elixir_msg,
             "Message mismatch: toxic #{inspect(toxic_msg)} vs elixir #{inspect(elixir_msg)}"
    end)
  end

  defp normalize_warnings(warnings) do
    warnings
    |> Enum.reverse()
    |> Enum.map(fn
      # Handle structured warnings from Toxic
      %Toxic.Warning{details: details} = warning ->
        line = details.line
        column = details.column
        # Get message from details if present, otherwise construct from token_display
        msg_str =
          case details do
            %{message: message} -> IO.iodata_to_binary(message)
            _ -> format_warning_message(warning)
          end

        {{line, column}, msg_str}

      # Handle legacy tuple format from Elixir tokenizer
      {{line, column}, message} ->
        msg_str = IO.iodata_to_binary(message)
        {{line, column}, msg_str}
    end)
  end

  # Format a warning message when no explicit message is stored
  defp format_warning_message(%Toxic.Warning{
         code: :deprecated_charlist,
         details: %{suggestion: _}
       }) do
    "single-quoted string represent charlists. Use ~c''' if you indeed want a charlist or use \"\"\" instead"
  end

  defp format_warning_message(%Toxic.Warning{
         code: :deprecated_single_quote_atom,
         details: %{suggestion: _}
       }) do
    "single quotes around atoms are deprecated. Use double quotes instead"
  end

  defp format_warning_message(%Toxic.Warning{details: %{message: message}}) do
    IO.iodata_to_binary(message)
  end

  defp format_warning_message(_warning) do
    # Fallback for any other case
    "unknown warning"
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.next(stream) do
      {:ok, token, new_stream} ->
        collect_all_tokens(new_stream, [token | acc])

      {:error, _reason, _final_stream} ->
        flunk("Unexpected error during tokenization")

      {:eof, final_stream} ->
        {Enum.reverse(acc), final_stream}
    end
  end

  # Character literal warnings
  test "character literal with escape followed by non-escaped char" do
    # ?\a should warn to use ?\\a
    tokenize_and_compare_warning("?\\a")
  end

  test "character literal unknown escape sequence" do
    # ?\\q should warn to use ?q
    tokenize_and_compare_warning("?\\q")
  end

  test "character literal non-escaped special char" do
    # ?\\t (code point) should warn to use ?\\t
    tokenize_and_compare_warning("?\\t")
  end

  # Charlist deprecation warnings
  test "single-quoted heredoc charlist" do
    tokenize_and_compare_warning("'''\nhello\n'''")
  end

  test "single-quoted string charlist" do
    tokenize_and_compare_warning("'hello'")
  end

  # Atom syntax warnings
  test "triple colon atom ambiguity" do
    tokenize_and_compare_warning(":::")
  end

  test "single quotes around atoms deprecated" do
    tokenize_and_compare_warning(":'1hello'")
  end

  test "unnecessary quotes around atoms" do
    tokenize_and_compare_warning(":'hello'")
    tokenize_and_compare_warning(":\"hello\"")
  end

  test "single quotes around keyword identifier deprecated" do
    tokenize_and_compare_warning("'1hello': 1")
  end

  test "unnecessary quotes around keyword identifier" do
    tokenize_and_compare_warning("'hello': 1")
    tokenize_and_compare_warning("\"hello\": 1")
  end

  # Repeated character operator warnings
  test "four ampersands warning" do
    tokenize_and_compare_warning("&&&& true")
  end

  test "four pipes warning" do
    tokenize_and_compare_warning("|||| true")
  end

  test "four plus warning" do
    tokenize_and_compare_warning("++++")
  end

  test "four minus warning" do
    tokenize_and_compare_warning("----")
  end

  test "four caret warning" do
    tokenize_and_compare_warning("^^^^")
  end

  # Ambiguous bang before equals warnings
  test "ambiguous bang before equals in atom" do
    tokenize_and_compare_warning(":foo!= 1")
  end

  test "ambiguous bang before equals in identifier" do
    tokenize_and_compare_warning("foo!= 1")
  end

  # Ambiguous question before equals warnings
  test "ambiguous question before equals in atom" do
    tokenize_and_compare_warning(":foo?= 1")
  end

  test "ambiguous question before equals in identifier" do
    tokenize_and_compare_warning("foo?= 1")
  end

  # Deprecated operator warnings
  test "deprecated xor operator ^^^" do
    tokenize_and_compare_warning("1 ^^^ 2")
  end

  test "deprecated bnot operator ~~~" do
    tokenize_and_compare_warning("~~~1")
  end

  test "deprecated pipe operator <|>" do
    tokenize_and_compare_warning("1 <|> 2")
  end

  # Dot syntax warnings
  test "single quotes around calls deprecated" do
    tokenize_and_compare_warning("Foo.'1bar'")
  end

  test "unnecessary quotes around calls" do
    tokenize_and_compare_warning("Foo.'bar'")
    tokenize_and_compare_warning("Foo.\"bar\"")
    tokenize_and_compare_warning("Foo.\"bar\"()")
    tokenize_and_compare_warning("Foo.\"bar\"[]")
    tokenize_and_compare_warning("Foo.\"bar\" +1")
    tokenize_and_compare_warning("Foo.\"bar\" do\n:ok\nend")
  end

  # Sigil escape warnings - uppercase sigil
  test "escaped delimiter in uppercase sigil" do
    tokenize_and_compare_warning("~S|foo\|")
  end
end
