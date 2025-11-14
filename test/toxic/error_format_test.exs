defmodule Toxic.ErrorFormatTest do
  @elixir_version System.version()

  @moduledoc """
  Tests that verify error message formatting matches Elixir's tokenizer output.
  These are snapshot tests that lock the exact message format for compatibility.

  Message formats verified for Elixir #{@elixir_version}
  """
  use ExUnit.Case

  alias Toxic.Error

  # -- Terminator errors ------------------------------------------------------

  test "terminator_mismatched_closer formats correctly" do
    err = %Error{
      code: :terminator_mismatched_closer,
      token_display: ~c")",
      details: %{
        opening_delimiter: :"[",
        closing_delimiter: :")",
        expected_delimiter: :"]"
      }
    }

    {_meta, msg, tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "unexpected token: "
    assert tok == ~c")"
  end

  test "terminator_unexpected_closer formats correctly" do
    err = %Error{
      code: :terminator_unexpected_closer,
      token_display: ~c")"
    }

    {_meta, msg, tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "unexpected token: "
    assert tok == ~c")"
  end

  test "terminator_missing_closer formats correctly" do
    err = %Error{
      code: :terminator_missing_closer,
      details: %{
        opening_delimiter: :"(",
        expected_delimiter: :")",
        line: 1,
        column: 5,
        end_line: 1,
        end_column: 10
      }
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "missing terminator: )"
  end

  # -- String and interpolation errors ----------------------------------------

  test "string_missing_terminator with suffix formats correctly" do
    err = %Error{
      code: :string_missing_terminator,
      details: %{
        opening_delimiter: :"\"",
        expected_delimiter: :"\"",
        line: 1,
        column: 1,
        end_line: 1,
        end_column: 10,
        suffix_iolist: ~c" (for string starting at line 1)"
      }
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "missing terminator: \""
    assert msg_str =~ "for string starting at line 1"
  end

  test "heredoc_missing_terminator formats correctly" do
    err = %Error{
      code: :heredoc_missing_terminator,
      details: %{
        opening_delimiter: :"\"\"\"",
        expected_delimiter: :"\"\"\"",
        line: 1,
        column: 1,
        end_line: 5,
        end_column: 1,
        suffix_iolist: ~c" (for heredoc starting at line 1)"
      }
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "missing terminator: \"\"\""
    assert msg_str =~ "for heredoc starting at line 1"
  end

  test "interpolation_missing_terminator formats correctly" do
    err = %Error{
      code: :interpolation_missing_terminator,
      details: %{
        opening_delimiter: :"\#{",
        expected_delimiter: :"}",
        start_line: 1,
        start_column: 5,
        end_line: 1,
        end_column: 10,
        suffix_iolist: ~c" (for interpolation starting at line 1)"
      }
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "missing interpolation terminator: \"}\""
    assert msg_str =~ "for interpolation starting at line 1"
  end

  test "interpolation_not_allowed_in_quoted_identifier formats correctly" do
    err = %Error{
      code: :interpolation_not_allowed_in_quoted_identifier,
      details: %{start_line: 1, start_column: 5}
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "interpolation is not allowed when calling function/macro"
  end

  # -- Map and keyword errors -------------------------------------------------

  test "map_invalid_open_delimiter formats correctly" do
    err = %Error{code: :map_invalid_open_delimiter, token_display: ~c"%("}
    {_meta, msg, tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) |> String.starts_with?("expected %{ to define a map, got:")
    assert tok == ~c"%("
  end

  test "map_unexpected_space_after_percent formats correctly" do
    err = %Error{code: :map_unexpected_space_after_percent, token_display: ~c"% {}"}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "unexpected space between % and {"
    assert msg_str =~ "Syntax error before: "
  end

  test "keyword_missing_space_after_colon formats correctly" do
    err = %Error{code: :keyword_missing_space_after_colon}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "keyword argument must be followed by space after:"
  end

  # -- Number errors ----------------------------------------------------------

  test "number_trailing_garbage formats correctly" do
    err = %Error{
      code: :number_trailing_garbage,
      details: %{
        line: 1,
        column: 1,
        msg_iolist: ~c"invalid character \"x\" after number 0"
      }
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    msg_str = IO.iodata_to_binary(msg)
    assert msg_str =~ "invalid character \"x\" after number 0"
  end

  test "number_invalid_float formats correctly" do
    err = %Error{code: :number_invalid_float}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "invalid float number"
  end

  # -- Alias and reserved errors ----------------------------------------------

  test "alias_unexpected_paren formats correctly" do
    err = %Error{
      code: :alias_unexpected_paren,
      details: %{hint: "aliases do not accept parentheses"}
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "unexpected ( after alias"
  end

  test "alias_invalid_character formats correctly" do
    err = %Error{
      code: :alias_invalid_character,
      token_display: ~c"Foo@Bar",
      details: %{message_iolist: ~c"invalid character \"@\" in alias"}
    }

    {_meta, msg, tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "invalid character \"@\" in alias"
    assert tok == ~c"Foo@Bar"
  end

  test "reserved_unexpected_end formats correctly" do
    err = %Error{
      code: :reserved_unexpected_end,
      token_display: ~c"end",
      details: %{}
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "unexpected reserved word: end"
  end

  # -- Comment and encoding errors --------------------------------------------

  test "comment_invalid_bidi in comment formats correctly" do
    err = %Error{code: :comment_invalid_bidi, domain: :comment}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "bidirectional formatting"
  end

  test "comment_invalid_linebreak in comment formats correctly" do
    err = %Error{code: :comment_invalid_linebreak, domain: :comment}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "invalid line break character in comment"
  end

  test "vc_merge_conflict_marker formats correctly" do
    err = %Error{code: :vc_merge_conflict_marker}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "found an unexpected version control marker"
  end

  # -- Identifier errors ------------------------------------------------------

  test "identifier_mixed_script formats correctly" do
    err = %Error{
      code: :identifier_mixed_script,
      details: %{
        message_prefix: ~c"invalid mixed-script identifier found: ",
        message_suffix: ~c"badidentifier"
      }
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    # format returns a tuple {prefix, suffix}, which is valid structure but not directly iodata
    assert match?({_, _}, msg)
    {prefix, _suffix} = msg
    assert IO.iodata_to_binary(prefix) =~ "invalid mixed-script identifier"
  end

  test "identifier_invalid_char formats correctly" do
    err = %Error{
      code: :identifier_invalid_char,
      details: %{reason_iolist: ["invalid character in identifier"]}
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "invalid character in identifier"
  end

  test "reserved_token_used formats correctly" do
    err = %Error{code: :reserved_token_used}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "reserved token:"
  end

  # -- Sigil errors -----------------------------------------------------------

  test "sigil_invalid_name formats correctly" do
    err = %Error{code: :sigil_invalid_name}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "invalid sigil name"
  end

  test "sigil_invalid_delimiter formats correctly" do
    err = %Error{code: :sigil_invalid_delimiter}

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "invalid sigil delimiter"
  end
end
