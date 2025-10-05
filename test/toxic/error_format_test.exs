defmodule ToxicErrorFormatTest do
  use ExUnit.Case

  alias Toxic.Error

  test "string missing terminator with suffix" do
    err = %Error{
      code: :string_missing_terminator,
      details: %{opening_delimiter: :")", expected_delimiter: :")", suffix_iolist: ~c" (for string starting at line 1)"}
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) =~ "missing terminator: )"
  end

  test "map invalid open delimiter message head" do
    err = %Error{code: :map_invalid_open_delimiter, token_display: ~c"%("}
    {_meta, msg, tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) |> String.starts_with?("expected %{ to define a map, got:")
    assert tok == ~c"%("
  end
end
