defmodule ToxicErrorFormatTest do
  use ExUnit.Case

  alias Toxic.Error

  @tag :skip
  test "mismatched terminator message parity (snapshot)" do
    err = %Error{
      code: :terminator_mismatched_closer,
      domain: :terminator,
      token_display: ~c")",
      position: {{1, 1}, {1, 2}},
      details: %{opening_delimiter: :"[", expected_delimiter: :"]", closing_delimiter: :")"}
    }

    {meta, msg, tok} = Error.to_reason_tuple(err)
    assert is_list(meta)
    assert is_list(tok)
    assert IO.iodata_to_binary(msg) == "unexpected token: )"
  end

  @tag :skip
  test "map invalid open delimiter snapshot" do
    err = %Error{
      code: :map_invalid_open_delimiter,
      domain: :map,
      token_display: ~c"%(",
      position: {{1, 1}, {1, 2}},
      details: %{got: ~c"("}
    }

    {_meta, msg, _tok} = Error.to_reason_tuple(err)
    assert IO.iodata_to_binary(msg) |> String.starts_with?("expected %{ to define a map, got %(")
  end
end
