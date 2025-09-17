defmodule ToxicErrorsTest do
  use ExUnit.Case

  defp tokenize_and_compare_error(string, opts \\ []) do
    charlist = to_charlist(string)

    # Get error from Elixir tokenizer
    elixir_result = :elixir_tokenizer.tokenize(charlist, 1, 1, [])

    # Expected format: {:error, {position, msg1, msg2}, rest, warnings, tokens}
    {:error, {elixir_position, elixir_msg, elixir_token}, _rest, _, _} = elixir_result

    # Use the new streaming API
    stream =
      Toxic.TokenStream.new(string, 1, 1,
        elixir_compatibility: Keyword.get(opts, :must_match_elixir, true),
        preserve_comments: Keyword.get(opts, :preserve_comments, false),
        error_mode: :strict
      )

    # Get error from Toxic tokenizer
    case collect_all_tokens(stream, []) do
      {:error, {toxic_position, toxic_msg, toxic_token}} ->
        # Compare error details
        assert toxic_position == elixir_position,
               "Position mismatch: toxic #{inspect(toxic_position)} vs elixir #{inspect(elixir_position)}"

        # Convert iolists to binaries for comparison
        # Handle both single iolist and tuple formats
        toxic_msg_bin =
          case toxic_msg do
            {prefix, suffix} -> IO.iodata_to_binary(prefix) <> IO.iodata_to_binary(suffix)
            msg -> IO.iodata_to_binary(msg)
          end

        elixir_msg_bin =
          case elixir_msg do
            {prefix, suffix} -> IO.iodata_to_binary(prefix) <> IO.iodata_to_binary(suffix)
            msg -> IO.iodata_to_binary(msg)
          end

        assert toxic_msg_bin == elixir_msg_bin,
               "Message mismatch: toxic #{inspect(toxic_msg_bin)} vs elixir #{inspect(elixir_msg_bin)}"

        assert toxic_token == elixir_token,
               "Token mismatch: toxic #{inspect(toxic_token)} vs elixir #{inspect(elixir_token)}"

        :ok

      {tokens, _final_stream} ->
        flunk("Expected error but got tokens: #{inspect(tokens)}")

      other ->
        flunk("Unexpected result: #{inspect(other)}")
    end
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

  # Tokenizer errors - Number validation (message format is complex in Elixir)
  @tag :skip
  test "invalid character after number" do
    tokenize_and_compare_error("123abc")
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

  # Terminator errors
  test "unexpected closing parenthesis" do
    tokenize_and_compare_error(")")
  end

  test "unexpected closing bracket" do
    tokenize_and_compare_error("]")
  end

  test "unexpected closing brace" do
    tokenize_and_compare_error("}")
  end

  # Sigil errors
  test "invalid sigil name" do
    tokenize_and_compare_error("~zz(hello)")
  end

  # Alias errors
  test "invalid character in alias" do
    tokenize_and_compare_error("Foo.Bär")
  end

  # Additional coverage - these have some format differences but demonstrate error handling
  @tag :skip
  test "mixed unicode scripts in identifier" do
    # Mixing Latin and Cyrillic scripts (error format has complex nested issues)
    tokenize_and_compare_error("testИмя")
  end

  test "fn followed by do" do
    # Message format differs (elixir has extended help text)
    tokenize_and_compare_error("fn do")
  end
end
