defmodule Toxic.ScopeColumnTest do
  use ExUnit.Case

  defp tokenize_with_ranges(source, line, column, opts \\ []) do
    stream =
      Toxic.new(source, line, column,
        elixir_compatibility: Keyword.get(opts, :must_match_elixir, true),
        preserve_comments: Keyword.get(opts, :preserve_comments, false),
        existing_atoms_only: Keyword.get(opts, :existing_atoms_only, false)
      )

    {tokens_rev, _final_stream} = collect_all_tokens(stream, [])
    tokens = Enum.reverse(tokens_rev)

    collapsed = Toxic.Legacy.collapse_linear_ranges(tokens)

    if Keyword.get(opts, :must_match_elixir, true) do
      toxic_legacy = Toxic.Legacy.ranges_to_legacy(collapsed)

      {:ok, _, _, _, elixir_tokens, _remaining} =
        :elixir_tokenizer.tokenize(to_charlist(source), line, column,
          indentation: column - 1,
          existing_atoms_only: Keyword.get(opts, :existing_atoms_only, false)
        )

      assert toxic_legacy == Enum.reverse(elixir_tokens)
    end

    collapsed
  end

  defp collect_all_tokens(stream, acc) do
    case Toxic.next(stream) do
      {:ok, token, new_stream} ->
        collect_all_tokens(new_stream, [token | acc])

      {:eof, final_stream} ->
        {acc, final_stream}
    end
  end

  test "eol end column uses base column" do
    toks = tokenize_with_ranges("1\n2", 10, 5)

    assert [
             {:int, {{10, 5}, {10, 6}, 1}, _},
             {:eol, {{10, 6}, {11, 5}, 1}, nil},
             {:int, {{11, 5}, {11, 6}, 2}, _}
           ] = toks
  end

  test "heredoc terminator uses base column" do
    toks = tokenize_with_ranges("\"\"\"\nfoo\n\"\"\"", 10, 5)

    assert [
             {:bin_heredoc, {{10, 5}, {12, 8}, nil}, 0, ["foo\n"]}
           ] = toks
  end
end
