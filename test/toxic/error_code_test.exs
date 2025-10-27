defmodule ToxicErrorCodeTest do
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

  # -- Helper functions -------------------------------------------------------

  defp assert_error_code(input, expected_code, opts \\ []) do
    stream = Toxic.TokenStream.new(input, 1, 1, Keyword.merge([error_mode: :tolerant], opts))
    tokens = collect_all_tokens(stream, [])

    error = Enum.find(tokens, fn t -> match?({:error_token, _, _}, t) end)

    assert error != nil, "Expected to find an error_token in stream for input: #{inspect(input)}"
    assert {:error_token, _meta, %Error{code: ^expected_code}} = error
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.TokenStream.next(stream) do
      {:ok, token, new_stream} -> collect_all_tokens(new_stream, [token | acc])
      {:eof, _} -> Enum.reverse(acc)
      {:error, _reason, _} -> flunk("Stream returned {:error, ...} in tolerant mode")
    end
  end
end
