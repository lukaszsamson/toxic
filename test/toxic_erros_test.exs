defmodule ToxicErrorsTest do
  use ExUnit.Case

  defp tokenize_and_compare_error(string, opts \\ []) do
    charlist = to_charlist(string)

    # Get error from Elixir tokenizer
    elixir_result = :elixir_tokenizer.tokenize(charlist, 1, 1, [])

    # Expected format: {:error, {position, msg1, msg2}, rest, warnings, tokens}
    {:error, {elixir_position, elixir_msg, elixir_token}, _rest, _, _} = elixir_result

    assert_fn = Keyword.get(opts, :assert, &default_assert/2)

    # Use the new streaming API
    stream =
      Toxic.TokenStream.new(string, 1, 1,
        elixir_compatibility: Keyword.get(opts, :must_match_elixir, true),
        preserve_comments: Keyword.get(opts, :preserve_comments, false),
        error_mode: :strict
      )

    # Get error from Toxic tokenizer
    case collect_all_tokens(stream, []) do
      {:error, toxic_reason} ->
        assert_fn.({elixir_position, elixir_msg, elixir_token}, toxic_reason)
        :ok

      {tokens, _final_stream} ->
        flunk("Expected error but got tokens: #{inspect(tokens)}")

      other ->
        flunk("Unexpected result: #{inspect(other)}")
    end
  end

  defp default_assert(elixir_reason, {_, _, _} = toxic_reason) do
    {elixir_position, elixir_msg, elixir_token} = normalize_reason(elixir_reason)
    {toxic_position, toxic_msg, toxic_token} = normalize_reason(toxic_reason)

    assert toxic_position == elixir_position,
           "Position mismatch: toxic #{inspect(toxic_position)} vs elixir #{inspect(elixir_position)}"

    assert toxic_msg == elixir_msg,
           "Message mismatch: toxic #{inspect(toxic_msg)} vs elixir #{inspect(elixir_msg)}"

    assert toxic_token == elixir_token,
           "Token mismatch: toxic #{inspect(toxic_token)} vs elixir #{inspect(elixir_token)}"
  end

  defp default_assert(elixir_reason, toxic_reason) do
    flunk(
      "Expected Toxic tokenizer to return Elixir-style error tuple. Elixir returned #{inspect(elixir_reason)}, toxic returned #{inspect(toxic_reason)}"
    )
  end

  defp normalize_message({prefix, suffix}) do
    try do
      IO.iodata_to_binary(prefix) <> IO.iodata_to_binary(suffix)
    rescue
      ArgumentError ->
        # Fallback for invalid iodata
        inspect(prefix) <> inspect(suffix)
    end
  end

  defp normalize_message(message) do
    try do
      IO.iodata_to_binary(message)
    rescue
      ArgumentError ->
        # Fallback for invalid iodata
        inspect(message)
    end
  end

  defp normalize_reason({position, message, token}) do
    normalized_token =
      try do
        IO.iodata_to_binary(token)
      rescue
        ArgumentError ->
          # If token is not valid iodata, convert to string representation
          inspect(token)
      end

    {position, normalize_message(message), normalized_token}
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.TokenStream.next(stream) do
      {:ok, token, new_stream} ->
        collect_all_tokens(new_stream, [token | acc])

      {:error, reason, _final_stream} ->
        {:error, reason}

      {:eof, final_stream} ->
        {Enum.reverse(acc), final_stream}
    end
  end

  # Tokenizer errors - Version Control
  test "vc merge conflict" do
    tokenize_and_compare_error("<<<<<<< foo")
  end

  # Tokenizer errors - Map syntax
  test "unexpected space between % and {" do
    tokenize_and_compare_error("% {}")
  end

  test "expected %{ to define a map, got %(" do
    tokenize_and_compare_error("%(")
  end

  test "expected %{ to define a map, got %[" do
    tokenize_and_compare_error("%[")
  end

  # Tokenizer errors - Escape sequences
  test "invalid escape at end of file (backslash)" do
    tokenize_and_compare_error("\\")
  end

  test "invalid escape at end of file (backslash newline)" do
    tokenize_and_compare_error("\\\n")
  end

  test "invalid escape at end of file (backslash CRLF)" do
    tokenize_and_compare_error("\\\r\n")
  end

  # Tokenizer errors - Comments
  test "invalid bidi character in comment" do
    tokenize_and_compare_error("#" <> <<0x202E::utf8>>)
  end

  test "unexpected token null byte" do
    tokenize_and_compare_error(<<0>>)
    tokenize_and_compare_error("\a")
    tokenize_and_compare_error("\b")
    tokenize_and_compare_error("\d")
    tokenize_and_compare_error("\e")
    tokenize_and_compare_error("\f")
    tokenize_and_compare_error("\r")
    tokenize_and_compare_error("\v")
  end

  # Tokenizer errors - Strings/Heredocs
  test "invalid char after string heredoc open" do
    tokenize_and_compare_error("\"\"\"foo\"\"\"",
      assert: fn elixir_reason, toxic_reason ->
        assert toxic_reason == :invalid_char_after_heredoc_open
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "heredoc allows only whitespace"
        assert token == "\"\"\""
      end
    )
  end

  # Tokenizer errors - Number validation
  test "invalid character after number" do
    tokenize_and_compare_error("123abc")
  end

  test "invalid character after float" do
    tokenize_and_compare_error("1.2a")
  end

  test "invalid float number" do
    tokenize_and_compare_error("1.0e309",
      assert: fn elixir_reason, toxic_reason ->
        case toxic_reason do
          {_, _, _} = tuple_reason ->
            default_assert(elixir_reason, tuple_reason)

          {:invalid_float, original} ->
            flunk(
              "Expected Toxic tokenizer to return Elixir-style error tuple for invalid float. " <>
                "Elixir returned #{inspect(elixir_reason)}, toxic returned {:invalid_float, #{inspect(original)}}"
            )

          other ->
            flunk(
              "Unexpected Toxic tokenizer result for invalid float. " <>
                "Elixir returned #{inspect(elixir_reason)}, toxic returned #{inspect(other)}"
            )
        end
      end
    )
  end

  # Tokenizer errors - Reserved tokens
  test "reserved token __aliases__" do
    tokenize_and_compare_error("__aliases__")
  end

  test "reserved token __block__" do
    tokenize_and_compare_error("__block__")
  end

  # Tokenizer errors - Keyword arguments
  test "keyword argument not followed by space" do
    tokenize_and_compare_error("foo:bar")
  end

  test "unexpected reserved word do after comma" do
    tokenize_and_compare_error("if true, do\n")
  end

  # Terminator errors
  test "unexpected closing parenthesis" do
    tokenize_and_compare_error(")",
      assert: fn _elixir_reason, _toxic_reason ->
        # Just test that we get an error
        :ok
      end
    )
  end

  test "unexpected closing bracket" do
    tokenize_and_compare_error("]",
      assert: fn _elixir_reason, _toxic_reason ->
        # Just test that we get an error
        :ok
      end
    )
  end

  test "unexpected closing brace" do
    tokenize_and_compare_error("}",
      assert: fn _elixir_reason, _toxic_reason ->
        # Just test that we get an error
        :ok
      end
    )
  end

  test "unexpected token after alias" do
    tokenize_and_compare_error("Foo(",
      assert: fn elixir_reason, toxic_reason ->
        assert toxic_reason == :unexpected_token_after_alias
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "unexpected ( after alias"
        assert token == "("
      end
    )
  end

  test "mismatched closing terminator" do
    tokenize_and_compare_error("([)",
      assert: fn elixir_reason, toxic_reason ->
        assert toxic_reason == :unexpected_token_or_reserved
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "unexpected token:"
        assert token == ")"
      end
    )
  end

  test "unexpected reserved word end" do
    tokenize_and_compare_error("end")
  end

  # Sigil errors
  test "invalid sigil name" do
    tokenize_and_compare_error("~zz(hello)")
  end

  test "invalid uppercase sigil name" do
    tokenize_and_compare_error("~Ab/foo/",
      assert: fn elixir_reason, toxic_reason ->
        {_position, toxic_message, _token} = toxic_reason
        assert IO.iodata_to_binary(toxic_message) =~ "invalid sigil name"
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "invalid sigil name"
        assert token |> to_string() |> String.starts_with?("~A")
      end
    )
  end

  test "invalid char after sigil heredoc open" do
    tokenize_and_compare_error("~S\"\"\"foo\"\"\"",
      assert: fn elixir_reason, toxic_reason ->
        {_position, toxic_message, _token} = toxic_reason
        assert IO.iodata_to_binary(toxic_message) =~ "heredoc allows only whitespace"
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "heredoc allows only whitespace"
        assert token == "\"\"\""
      end
    )
  end

  test "invalid sigil delimiter" do
    tokenize_and_compare_error("~s!foo!",
      assert: fn elixir_reason, toxic_reason ->
        {_position, toxic_message, _token} = toxic_reason
        assert IO.iodata_to_binary(toxic_message) =~ "invalid sigil delimiter"
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "invalid sigil delimiter"
        assert token =~ "code point U+0021"
        assert token =~ "The available delimiters are:"
      end
    )
  end

  # Alias errors
  test "invalid character in alias" do
    tokenize_and_compare_error("Foo.Bär")
  end

  # Additional coverage - these have some format differences but demonstrate error handling
  test "fn followed by do" do
    # Message format differs (elixir has extended help text)
    tokenize_and_compare_error("fn do")
  end

  # Identifier errors
  test "identifier exceeding atom length limit" do
    tokenize_and_compare_error(String.duplicate("a", 256),
      assert: fn elixir_reason, toxic_reason ->
        assert toxic_reason == :atom_length_system_limit
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "atom length must be less than system limit"
        assert String.length(token) == 256
      end
    )
  end

  test "mixed script identifier" do
    tokenize_and_compare_error("foo" <> <<0x03B1::utf8>> <> "bar")
  end

  test "mixed script identifier without suggestion" do
    tokenize_and_compare_error("foo" <> <<0x0402::utf8>>)
  end

  test "identifier confusable suggestion" do
    tokenize_and_compare_error("foO" <> <<0x1D6B3::utf8>>)
  end

  test "identifier nfkc suggestion" do
    tokenize_and_compare_error("foo" <> <<0x06CC::utf8>> <> <<0x1D6B3::utf8>>)
  end

  test "unexpected token in identifier" do
    tokenize_and_compare_error(<<0x3164::utf8>>)
  end

  test "unexpected token identifier control char" do
    tokenize_and_compare_error("foo" <> <<0x0080::utf8>>)
  end

  test "unexpected token identifier control char in atom" do
    tokenize_and_compare_error(":foo" <> <<0x0080::utf8>>)
  end

  test "empty identifier after colon" do
    tokenize_and_compare_error(":")
  end

  test "unexpected token after colon" do
    tokenize_and_compare_error(":" <> <<0x200B::utf8>>)
  end

  test "unexpected token after colon with zero width joiner" do
    tokenize_and_compare_error(":" <> <<0x200C::utf8>>)
  end

  test "unexpected token after colon confusable suggestion" do
    tokenize_and_compare_error(":" <> "foO" <> <<0x1D6B3::utf8>>)
  end

  test "unexpected token after colon control char" do
    tokenize_and_compare_error(":" <> <<0x0080::utf8>>)
  end

  test "identifier containing @" do
    tokenize_and_compare_error("foo@bar")
  end

  test "unexpected token fallback" do
    tokenize_and_compare_error(<<0x03A9::utf8>>)
  end

  # Dot handling
  test "invalid bidi character in dot comment" do
    tokenize_and_compare_error(".#" <> <<0x202E::utf8>>,
      assert: fn elixir_reason, toxic_reason ->
        assert toxic_reason == :comment_bidi_error
        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "invalid bidirectional formatting character in comment"
        assert token == "\\u202E"
      end
    )
  end

  # Interpolation errors
  test "invalid bidi character in string" do
    tokenize_and_compare_error("\"" <> <<0x202E::utf8>> <> "\"",
      assert: fn elixir_reason, toxic_reason ->
        {_position, toxic_message, _token} = toxic_reason

        assert IO.iodata_to_binary(toxic_message) =~
                 "invalid bidirectional formatting character in string"

        {_position, message, token} = normalize_reason(elixir_reason)
        assert message =~ "invalid bidirectional formatting character in string"
        assert token == "\\u202E"
      end
    )
  end

  # Ternary errors
  test "unexpected ternary token" do
    tokenize_and_compare_error("..//foo")
  end

  test "consecutive semicolons" do
    tokenize_and_compare_error(";;")
  end
end
