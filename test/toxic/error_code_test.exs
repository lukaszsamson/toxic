defmodule ToxicErrorCodeTest do
  use ExUnit.Case

  # These are scaffolding tests; skip until producers emit Toxic.Error structs.

  @tag :skip
  test "tolerant mode emits structured error code for invalid map opener" do
    stream = Toxic.TokenStream.new("%( )", 1, 1, error_mode: :tolerant)
    tokens = collect_all_tokens(stream, [])

    error = Enum.find(tokens, fn t -> match?({:error_token, _, _}, t) end)
    assert {:error_token, _meta, %Toxic.Error{code: :map_invalid_open_delimiter}} = error
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.TokenStream.next(stream) do
      {:ok, token, new_stream} -> collect_all_tokens(new_stream, [token | acc])
      {:eof, _} -> Enum.reverse(acc)
      {:error, _reason, _} -> flunk("Stream returned {:error, ...} in tolerant mode")
    end
  end
end
