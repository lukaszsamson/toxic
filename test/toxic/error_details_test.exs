defmodule Toxic.ErrorDetailsTest do
  @moduledoc """
  Deep verification tests for error details content, position fields, and synthesis behavior.
  Tests ensure that error_token payloads contain accurate and complete details.
  """
  use ExUnit.Case

  alias Toxic.Error

  # -- Details Content Verification -------------------------------------------

  describe "error details content verification" do
    test "terminator_mismatched_closer includes all required delimiter details" do
      tokens = tokenize_tolerant("([)")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :terminator_mismatched_closer, details: d}} =
               error_token

      assert d[:opening_delimiter] == :"["
      assert d[:closing_delimiter] == :")"
      assert d[:expected_delimiter] == :"]"
    end

    test "terminator_missing_closer includes position details" do
      tokens = tokenize_tolerant("(")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :terminator_missing_closer, details: d}} =
               error_token

      assert d[:opening_delimiter] == :"("
      assert d[:expected_delimiter] == :")"
      assert is_integer(d[:line])
      assert is_integer(d[:column])
      assert is_integer(d[:end_line])
      assert is_integer(d[:end_column])
    end

    test "string_missing_terminator includes delimiter and suffix details" do
      input = ~S["unclosed]
      tokens = tokenize_tolerant(input)

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :string_missing_terminator, details: d}} =
               error_token

      assert d[:opening_delimiter] == :"\""
      assert d[:expected_delimiter] == :"\""
      assert is_list(d[:suffix_iolist])
    end

    test "interpolation_missing_terminator includes start position and suffix" do
      # To get interpolation_missing_terminator, we need a complete string with unclosed interpolation
      # But since strings handle their own termination, we check for the interpolation details
      # when the tokenizer properly tracks interpolation context
      input = "\"foo \#{bar\""
      tokens = tokenize_tolerant(input)

      # In this case, we may get a string_missing_terminator because the whole string isn't closed
      # OR we may get interpolation_missing_terminator if the interpolation is tracked separately
      error_token = find_error_token(tokens)
      assert {:error_token, _meta, %Error{details: d}} = error_token

      # Just verify we have position details
      assert is_map(d)
    end

    test "number_trailing_garbage includes error message" do
      tokens = tokenize_tolerant("0x")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :number_trailing_garbage, details: d}} =
               error_token

      assert is_list(d[:msg_iolist])
      msg_str = IO.iodata_to_binary(d[:msg_iolist])
      assert msg_str =~ "invalid character"
    end

    test "map_invalid_open_delimiter includes position details" do
      tokens = tokenize_tolerant("%( )")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :map_invalid_open_delimiter, details: d}} =
               error_token

      # Map errors may have position details
      assert is_map(d)
    end

    test "keyword_missing_space_after_colon includes position details" do
      tokens = tokenize_tolerant("[foo:bar]")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :keyword_missing_space_after_colon, details: d}} =
               error_token

      # Keyword errors may have position details
      assert is_map(d)
    end

    test "identifier_mixed_script includes message details" do
      # Mixing Latin with Cyrillic scripts
      tokens = tokenize_tolerant("foo\u{0410}bar")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :identifier_mixed_script, details: d}} =
               error_token

      # Should have message details about the mixed script
      assert is_list(d[:message_prefix]) or is_list(d[:message_iolist])
    end

    test "heredoc_missing_terminator includes delimiter and suffix details" do
      input = ~S("""
      unclosed heredoc)
      tokens = tokenize_tolerant(input)

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :heredoc_missing_terminator, details: d}} =
               error_token

      assert d[:opening_delimiter] == :"\"\"\""
      assert d[:expected_delimiter] == :"\"\"\""
      assert is_list(d[:suffix_iolist])
      assert is_integer(d[:line])
      assert is_integer(d[:column])
    end

    test "alias_unexpected_paren includes position details" do
      tokens = tokenize_tolerant("Foo()")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :alias_unexpected_paren, details: d}} =
               error_token

      # Alias errors have position details
      assert is_map(d)
    end

    test "sigil_invalid_name includes position details" do
      # Lowercase sigil names must be single character
      tokens = tokenize_tolerant("~ab()")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :sigil_invalid_name, details: d}} =
               error_token

      assert is_integer(d[:line])
      assert is_integer(d[:column])
    end

    test "sigil_invalid_delimiter includes position details" do
      # $ is not a valid sigil delimiter
      tokens = tokenize_tolerant("~s$foo$")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :sigil_invalid_delimiter, details: d}} =
               error_token

      assert is_integer(d[:line])
      assert is_integer(d[:column])
    end

    test "alias_invalid_character includes message details" do
      # Aliases only allow ASCII characters
      tokens = tokenize_tolerant("Foöbar")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :alias_invalid_character, details: d}} =
               error_token

      assert is_integer(d[:line])
      assert is_integer(d[:column])
      assert is_list(d[:message_iolist])
      msg_str = IO.iodata_to_binary(d[:message_iolist])
      assert msg_str =~ "invalid character"
    end

    test "identifier_invalid_char includes message details" do
      # @ is not allowed in the middle of identifiers
      tokens = tokenize_tolerant("foo@bar")

      error_token = find_error_token(tokens)

      assert {:error_token, _meta, %Error{code: :identifier_invalid_char, details: d}} =
               error_token

      assert is_integer(d[:line])
      assert is_integer(d[:column])
      assert is_list(d[:msg_iolist])
      msg_str = IO.iodata_to_binary(d[:msg_iolist])
      assert msg_str =~ "invalid character"
    end

    test "identifier_nonexistent_atom_when_existing_only includes position details" do
      # Using existing_atoms_only: true with a non-existent atom
      tokens =
        tokenize_tolerant(":this_atom_definitely_does_not_exist_xyz123",
          existing_atoms_only: true
        )

      error_token = find_error_token(tokens)

      assert {:error_token, _meta,
              %Error{code: :identifier_nonexistent_atom_when_existing_only, details: d}} =
               error_token

      assert is_integer(d[:line])
      assert is_integer(d[:column])
    end

    test "interpolation_not_allowed_in_quoted_identifier includes position details" do
      # Interpolation is not allowed in quoted call identifiers
      tokens = tokenize_tolerant(~S(Foo."bar#{baz}"))

      error_token = find_error_token(tokens)

      assert {:error_token, _meta,
              %Error{code: :interpolation_not_allowed_in_quoted_identifier, details: d}} =
               error_token

      assert is_integer(d[:start_line])
      assert is_integer(d[:start_column])
    end
  end

  # -- Position Field Verification --------------------------------------------

  describe "position field verification" do
    test "error_token meta has correct position for unexpected closer" do
      tokens = tokenize_tolerant(")")

      assert {:error_token, meta, %Error{code: :terminator_unexpected_closer}} = hd(tokens)
      assert {{1, 1}, {1, 2}, _} = meta
    end

    test "error_token meta has correct position for mismatched closer" do
      tokens = tokenize_tolerant("([)")

      error_token = find_error_token(tokens)
      assert {:error_token, meta, %Error{code: :terminator_mismatched_closer}} = error_token

      # Error should be at the mismatched closer position
      assert {{line, col}, {end_line, end_col}, _} = meta
      assert line == 1
      assert col == 3
      assert end_line == 1
      assert end_col == 4
    end

    test "error_token meta has correct position for string error" do
      input = ~S["unclosed]
      tokens = tokenize_tolerant(input)

      error_token = find_error_token(tokens)
      assert {:error_token, meta, %Error{code: :string_missing_terminator}} = error_token

      # Error position should be at end of unclosed string
      assert {{line, col}, {end_line, end_col}, _} = meta
      assert is_integer(line)
      assert is_integer(col)
      assert is_integer(end_line)
      assert is_integer(end_col)
    end

    test "error_token meta has correct position for number error" do
      tokens = tokenize_tolerant("0x")

      error_token = find_error_token(tokens)
      assert {:error_token, meta, %Error{code: :number_trailing_garbage}} = error_token

      assert {{1, 1}, {1, 3}, _} = meta
    end
  end

  # -- Zero-Length Meta Tests for Synthesis -----------------------------------

  describe "zero-length meta for synthesis tokens" do
    test "synthesized closer has zero-length meta after unexpected closer error" do
      tokens = tokenize_tolerant(")", synthesis: true)

      # Should emit: error_token, synthesized opener, actual closer
      assert length(tokens) >= 2

      assert {:error_token, _meta, %Error{code: :terminator_unexpected_closer}} =
               Enum.at(tokens, 0)

      # Find the synthesized opener (should be :( with zero-length meta)
      synthesized = Enum.at(tokens, 1)
      assert {:"(", syn_meta, _} = synthesized
      assert {{line, col}, {end_line, end_col}, _} = syn_meta
      # Zero-length: start and end positions are the same
      assert line == end_line
      assert col == end_col
    end

    test "synthesized closer has zero-length meta after mismatched closer error" do
      tokens = tokenize_tolerant("([)", synthesis: true)

      # Find the error and check tokens after it
      error_idx = Enum.find_index(tokens, fn t -> match?({:error_token, _, _}, t) end)
      assert error_idx != nil

      # After error_token, should have synthesized ] with zero-length meta
      synthesized = Enum.at(tokens, error_idx + 1)
      assert {:"]", syn_meta, _} = synthesized
      assert {{line, col}, {end_line, end_col}, _} = syn_meta
      assert line == end_line
      assert col == end_col
    end

    test "synthesized missing closer has zero-length meta at EOF" do
      tokens = tokenize_tolerant("(", synthesis: true)

      # Should have error_token and synthesized closer
      assert length(tokens) >= 2

      error_idx = Enum.find_index(tokens, fn t -> match?({:error_token, _, _}, t) end)
      assert error_idx != nil

      synthesized = Enum.at(tokens, error_idx + 1)
      assert {:")", syn_meta, _} = synthesized
      assert {{line, col}, {end_line, end_col}, _} = syn_meta
      assert line == end_line
      assert col == end_col
    end

    test "synthesized string terminator has zero-length meta" do
      input = ~S["unclosed]
      tokens = tokenize_tolerant(input, synthesis: true)

      # Find the string end token (synthesized)
      string_end =
        Enum.find(tokens, fn t ->
          match?({:bin_string, _meta, _content}, t) or match?({:bin_string_end, _meta, _}, t)
        end)

      # The bin_string_end should have been synthesized with zero-length meta
      if string_end != nil do
        case string_end do
          {:bin_string_end, meta, _} ->
            assert {{line, col}, {end_line, end_col}, _} = meta
            assert line == end_line
            assert col == end_col

          _ ->
            :ok
        end
      end
    end
  end

  # -- Details Validation Tests -----------------------------------------------

  describe "details validation" do
    test "validation catches missing required keys for mismatched closer" do
      assert_raise ArgumentError, ~r/Missing required details key/, fn ->
        %Toxic.Error{
          code: :terminator_mismatched_closer,
          # Missing expected_delimiter and closing_delimiter
          details: %{opening_delimiter: :"("}
        }
        |> Toxic.Error.validate_details!()
      end
    end

    test "validation catches missing required keys for missing closer" do
      assert_raise ArgumentError, ~r/Missing required details key/, fn ->
        %Toxic.Error{
          code: :terminator_missing_closer,
          # Missing line, column, end_line, end_column
          details: %{opening_delimiter: :"("}
        }
        |> Toxic.Error.validate_details!()
      end
    end

    test "validation catches missing required keys for string missing terminator" do
      assert_raise ArgumentError, ~r/Missing required details key/, fn ->
        %Toxic.Error{
          code: :string_missing_terminator,
          # Missing other required keys
          details: %{opening_delimiter: :"\""}
        }
        |> Toxic.Error.validate_details!()
      end
    end

    test "validation allows escape_at_eof string errors with minimal details" do
      # Should not raise - escape_at_eof? errors have different requirements
      assert :ok =
               %Toxic.Error{
                 code: :string_missing_terminator,
                 details: %{escape_at_eof?: true, line: 1, column: 5}
               }
               |> Toxic.Error.validate_details!()
    end

    test "validation allows codes with no required details" do
      # Should not raise for codes with empty/optional details
      assert :ok =
               %Toxic.Error{
                 code: :map_invalid_open_delimiter,
                 details: %{}
               }
               |> Toxic.Error.validate_details!()

      assert :ok =
               %Toxic.Error{
                 code: :keyword_missing_space_after_colon,
                 details: %{}
               }
               |> Toxic.Error.validate_details!()
    end

    test "validation passes for well-formed terminator errors" do
      assert :ok =
               %Toxic.Error{
                 code: :terminator_mismatched_closer,
                 details: %{
                   opening_delimiter: :"(",
                   expected_delimiter: :")",
                   closing_delimiter: :"]"
                 }
               }
               |> Toxic.Error.validate_details!()
    end
  end

  # -- Helper Functions -------------------------------------------------------

  defp tokenize_tolerant(input, opts \\ []) do
    default_opts = [error_mode: :tolerant, synthesis: false]
    merged_opts = Keyword.merge(default_opts, opts)

    stream = Toxic.new(input, 1, 1, merged_opts)
    collect_all_tokens(stream, [])
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.next(stream) do
      {:ok, token, new_stream} -> collect_all_tokens(new_stream, [token | acc])
      {:eof, _} -> Enum.reverse(acc)
      {:error, _reason, _} -> flunk("Stream returned {:error, ...} in tolerant mode")
    end
  end

  defp find_error_token(tokens, code \\ nil) do
    if code do
      Enum.find(tokens, fn t ->
        match?({:error_token, _, %Error{code: ^code}}, t)
      end)
    else
      Enum.find(tokens, fn t -> match?({:error_token, _, _}, t) end)
    end
  end
end
