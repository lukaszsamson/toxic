defmodule Toxic.ErrorCodeTest do
  @moduledoc """
  Tests that verify tolerant mode emits the correct error codes for various error scenarios.
  Each test verifies that the error_token contains a Toxic.Error struct with the expected code.
  """
  use ExUnit.Case

  alias Toxic.Error

  # -- Terminator errors ------------------------------------------------------

  test "unexpected closer emits terminator_unexpected_closer" do
    assert_error_code(")", :terminator_unexpected_closer)
  end

  test "mismatched closer emits terminator_mismatched_closer" do
    assert_error_code("([)", :terminator_mismatched_closer)
  end

  test "missing closer at EOF emits terminator_missing_closer" do
    assert_error_code("(", :terminator_missing_closer)
  end

  test "unexpected end keyword emits reserved_unexpected_end" do
    assert_error_code("end", :reserved_unexpected_end)
  end

  # -- Map errors -------------------------------------------------------------

  test "map with invalid open delimiter emits map_invalid_open_delimiter" do
    assert_error_code("%( )", :map_invalid_open_delimiter)
  end

  test "map with space after percent emits map_unexpected_space_after_percent" do
    assert_error_code("% {}", :map_unexpected_space_after_percent)
  end

  # -- Keyword errors ---------------------------------------------------------

  test "keyword without space after colon emits keyword_missing_space_after_colon" do
    assert_error_code("[foo:bar]", :keyword_missing_space_after_colon)
  end

  # -- String and interpolation errors ----------------------------------------

  test "missing string terminator emits string_missing_terminator" do
    assert_error_code(~S("unclosed), :string_missing_terminator)
  end

  test "missing interpolation terminator emits interpolation_missing_terminator" do
    assert_error_code(~S("foo #{bar"), :interpolation_missing_terminator)
  end

  # -- Number errors ----------------------------------------------------------

  test "number with trailing garbage emits number_trailing_garbage" do
    assert_error_code("0x", :number_trailing_garbage)
  end

  test "invalid float emits number_invalid_float" do
    # Float too large for Erlang's float representation
    assert_error_code("1.0e309", :number_invalid_float)
  end

  # -- Syntax errors ----------------------------------------------------------

  test "consecutive semicolons emit syntax_consecutive_semicolons" do
    assert_error_code(";;", :syntax_consecutive_semicolons)
  end

  # -- Alias errors -----------------------------------------------------------

  test "alias with unexpected paren emits alias_unexpected_paren" do
    assert_error_code("Foo()", :alias_unexpected_paren)
  end

  test "alias with non-ASCII character emits alias_invalid_character" do
    # Aliases only allow ASCII characters, ö is invalid
    assert_error_code("Foöbar", :alias_invalid_character)
  end

  # -- Heredoc errors ---------------------------------------------------------

  test "heredoc missing terminator emits heredoc_missing_terminator" do
    input = ~S("""
    unclosed heredoc)
    assert_error_code(input, :heredoc_missing_terminator)
  end

  test "heredoc with invalid header emits heredoc_invalid_header" do
    # Heredoc with invalid sigil modifier or delimiter
    assert_error_code(~S("""invalid), :heredoc_invalid_header)
  end

  # -- Sigil errors -----------------------------------------------------------

  test "sigil with invalid lowercase name emits sigil_invalid_name" do
    # Lowercase sigil names must be single character, ~ab is invalid
    assert_error_code("~ab()", :sigil_invalid_name)
  end

  test "sigil with mixed case name emits sigil_invalid_name" do
    # Uppercase sigil followed by lowercase is invalid
    assert_error_code("~Ab()", :sigil_invalid_name)
  end

  test "sigil with invalid delimiter emits sigil_invalid_delimiter" do
    # $ is not a valid sigil delimiter
    assert_error_code("~s$foo$", :sigil_invalid_delimiter)
  end

  # -- Identifier errors ------------------------------------------------------

  test "identifier with mixed script emits identifier_mixed_script" do
    # Mixing Latin with Cyrillic scripts
    assert_error_code("foo\u{0410}bar", :identifier_mixed_script)
  end

  test "identifier with @ character emits identifier_invalid_char" do
    # @ is not allowed in the middle of identifiers
    assert_error_code("foo@bar", :identifier_invalid_char)
  end

  test "nonexistent atom with existing_atoms_only emits identifier_nonexistent_atom_when_existing_only" do
    # Using existing_atoms_only: true with a non-existent atom
    assert_error_code(
      ":this_atom_definitely_does_not_exist_xyz123",
      :identifier_nonexistent_atom_when_existing_only, existing_atoms_only: true)
  end

  # -- Comment errors ---------------------------------------------------------

  test "comment with invalid bidi character emits comment_invalid_bidi" do
    # Bidirectional control character in comment
    input = "# comment with bidi \u{202E}"
    assert_error_code(input, :comment_invalid_bidi)
  end

  test "comment with invalid linebreak emits comment_invalid_linebreak" do
    # Invalid linebreak character in comment (e.g., LINE SEPARATOR U+2028)
    input = "# comment with line\u{2028}break"
    assert_error_code(input, :comment_invalid_linebreak)
  end

  # -- Version control errors -------------------------------------------------

  test "merge conflict marker emits vc_merge_conflict_marker" do
    assert_error_code("<<<<<<< HEAD", :vc_merge_conflict_marker)
  end

  # -- Interpolation errors ---------------------------------------------------

  test "interpolation in quoted identifier emits interpolation_not_allowed_in_quoted_identifier" do
    # Interpolation is not allowed in quoted call identifiers like Foo."bar#{baz}"
    assert_error_code(~S(Foo."bar#{baz}"), :interpolation_not_allowed_in_quoted_identifier)
  end

  # -- Repro cases errors ---------------------------------------------------

  test "missing_scope_hint repro" do
    assert_error_code(~S(fn x when fn{'% -> 1 end), :string_missing_terminator)
  end

  # -- Helper functions -------------------------------------------------------

  defp assert_error_code(input, expected_code, opts \\ []) do
    stream = Toxic.new(input, 1, 1, Keyword.merge([error_mode: :tolerant], opts))
    tokens = collect_all_tokens(stream, [])

    error = Enum.find(tokens, fn t -> match?({:error_token, _, _}, t) end)

    assert error != nil, "Expected to find an error_token in stream for input: #{inspect(input)}"
    assert {:error_token, _meta, %Error{code: ^expected_code}} = error
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.next(stream) do
      {:ok, token, new_stream} -> collect_all_tokens(new_stream, [token | acc])
      {:eof, _} -> Enum.reverse(acc)
      {:error, _reason, _} -> flunk("Stream returned {:error, ...} in tolerant mode")
    end
  end
end
