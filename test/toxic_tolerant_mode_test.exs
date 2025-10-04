defmodule ToxicTolerantModeTest do
  use ExUnit.Case

  # Helper to tokenize in tolerant mode
  defp tokenize_tolerant(string, opts \\ []) do
    stream =
      Toxic.TokenStream.new(string, 1, 1,
        error_mode: :tolerant,
        elixir_compatibility: false,
        preserve_comments: false
      )

    opts = Keyword.merge([include_errors: true], opts)
    collect_all_tokens(stream, [], opts)
  end

  defp collect_all_tokens(stream, acc, opts) do
    case Toxic.TokenStream.next(stream) do
      {:ok, token, new_stream} ->
        # Optionally filter out error tokens for continuation testing
        acc =
          if Keyword.get(opts, :include_errors, true) or elem(token, 0) != :error_token do
            [token | acc]
          else
            acc
          end

        collect_all_tokens(new_stream, acc, opts)

      {:eof, _final_stream} ->
        Enum.reverse(acc)

      {:error, _reason, _final_stream} ->
        # This should not happen in tolerant mode
        flunk("Tolerant mode returned {:error, ...} tuple - should have continued")
    end
  end

  # Helper to extract just token types for readability
  defp token_types(tokens) do
    Enum.map(tokens, &elem(&1, 0))
  end

  # Helper to safely extract token value (handles 2 and 3-element tokens)
  defp get_token_value(token) do
    case tuple_size(token) do
      3 -> elem(token, 2)
      2 -> nil
      _ -> nil
    end
  end

  # Helper to find error tokens
  defp error_tokens(tokens) do
    Enum.filter(tokens, fn token -> elem(token, 0) == :error_token end)
  end

  # Helper to find non-error tokens
  defp valid_tokens(tokens) do
    Enum.filter(tokens, fn token -> elem(token, 0) != :error_token end)
  end

  # Helper to verify forward progress (no position regression)
  defp assert_forward_progress(tokens) do
    positions =
      Enum.map(tokens, fn token ->
        case token do
          {_, {{sl, sc}, {el, ec}, _}, _} -> {{sl, sc}, {el, ec}}
          {_, {{sl, sc}, {el, ec}, _}} -> {{sl, sc}, {el, ec}}
          {_, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Verify positions never go backwards
    Enum.reduce(positions, {{1, 1}, {1, 1}}, fn {start, finish}, {_prev_start, prev_end} ->
      assert start >= prev_end,
             "Position regression: #{inspect(start)} < #{inspect(prev_end)}"

      {start, finish}
    end)

    :ok
  end

  # ============================================================================
  # Category 1: Invalid Characters & Control Sequences
  # ============================================================================

  describe "Category 1: Invalid characters" do
    test "null byte with continuation" do
      # Input: foo\0bar + baz
      # Note: \0bar is scanned as part of error until we hit space before +
      tokens = tokenize_tolerant("foo" <> <<0>> <> "bar + baz")

      assert length(error_tokens(tokens)) == 1
      # Error consumes "\0bar " up to the space, then + baz are tokenized
      assert [:identifier, :error_token, :dual_op, :identifier] = token_types(tokens)

      # Verify continuation tokens are correct
      valid = valid_tokens(tokens)
      assert get_token_value(Enum.at(valid, 0)) == :foo
      assert {:dual_op, _, :+} = Enum.at(valid, 1)
      assert get_token_value(Enum.at(valid, 2)) == :baz

      assert_forward_progress(tokens)
    end

    test "control char carriage return with continuation" do
      # \r is invalid outside strings
      tokens = tokenize_tolerant("foo\rbar")

      assert length(error_tokens(tokens)) == 1
      assert [:identifier, :error_token, :identifier] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {_, _, :foo} = Enum.at(valid, 0)
      assert {_, _, :bar} = Enum.at(valid, 1)
    end

    test "multiple invalid chars in sequence" do
      tokens = tokenize_tolerant("foo" <> <<0>> <> "bar" <> <<0>> <> "baz")

      assert length(error_tokens(tokens)) == 2
      assert [:identifier, :error_token, :identifier, :error_token, :identifier] =
               token_types(tokens)

      assert_forward_progress(tokens)
    end

    test "vc merge conflict with continuation" do
      tokens = tokenize_tolerant("<<<<<<< foo\nbar + baz")

      assert length(error_tokens(tokens)) == 1
      # Error should be on first line, then bar + baz on second
      assert [:error_token, :identifier, :dual_op, :identifier] = token_types(tokens)

      {:error_token, meta, _reason} = Enum.at(tokens, 0)
      # Error should span the entire conflict marker line
      assert {{1, 1}, {2, 1}, _} = meta
    end
  end

  # ============================================================================
  # Category 2: Malformed Numbers
  # ============================================================================

  describe "Category 2: Malformed numbers" do
    test "invalid char after number with continuation" do
      tokens = tokenize_tolerant("123abc + 456")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :dual_op, :int] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {:dual_op, _, :+} = Enum.at(valid, 0)
      assert {:int, _, 456} = Enum.at(valid, 1)

      # Error should cover "123abc"
      {:error_token, meta, _reason} = Enum.at(tokens, 0)
      assert {{1, 1}, {1, 7}, _} = meta
    end

    test "invalid char after float with continuation" do
      tokens = tokenize_tolerant("1.2a + 3.4")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :dual_op, :flt] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {:flt, _, 3.4} = Enum.at(valid, 1)
    end

    test "float overflow with continuation" do
      tokens = tokenize_tolerant("1.0e309 + 42")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :dual_op, :int] = token_types(tokens)
    end

    test "number error at end of expression" do
      tokens = tokenize_tolerant("x = 123abc")

      assert length(error_tokens(tokens)) == 1
      assert [:identifier, :match_op, :error_token] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {_, _, :x} = Enum.at(valid, 0)
      assert {:match_op, _, :=} = Enum.at(valid, 1)
    end
  end

  # ============================================================================
  # Category 3: Invalid Escape Sequences
  # ============================================================================

  describe "Category 3: Invalid escape sequences" do
    test "backslash at EOF after valid tokens" do
      tokens = tokenize_tolerant("foo + bar\\")

      assert length(error_tokens(tokens)) == 1
      assert [:identifier, :dual_op, :identifier, :error_token] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {_, _, :foo} = Enum.at(valid, 0)
      assert {:dual_op, _, :+} = Enum.at(valid, 1)
      assert {_, _, :bar} = Enum.at(valid, 2)
    end

    test "backslash newline at EOF" do
      tokens = tokenize_tolerant("x\\\n")

      assert length(error_tokens(tokens)) == 1
      assert [:identifier, :error_token] = token_types(tokens)
    end

    test "backslash CRLF at EOF" do
      tokens = tokenize_tolerant("y\\\r\n")

      assert length(error_tokens(tokens)) == 1
      assert [:identifier, :error_token] = token_types(tokens)
    end
  end

  # ============================================================================
  # Category 4: Terminator Mismatches
  # ============================================================================

  describe "Category 4: Terminator mismatches" do
    test "unexpected closing paren with continuation" do
      tokens = tokenize_tolerant(") + foo")

      assert length(error_tokens(tokens)) == 1
      # In Phase 1 (no insertions), we just emit error and skip the )
      # Then continue with + foo
      assert [:error_token, :dual_op, :identifier] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {:dual_op, _, :+} = Enum.at(valid, 0)
      assert {_, _, :foo} = Enum.at(valid, 1)
    end

    test "unexpected closing bracket with continuation" do
      tokens = tokenize_tolerant("] ; bar")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :";" , :identifier] = token_types(tokens)
    end

    test "unexpected closing brace" do
      tokens = tokenize_tolerant("} , baz")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :"," , :identifier] = token_types(tokens)
    end

    test "unexpected bitstring close" do
      tokens = tokenize_tolerant(">> + x")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :dual_op, :identifier] = token_types(tokens)
    end

    test "mismatched delimiter with continuation" do
      tokens = tokenize_tolerant("([) + x")

      # Should get: ( [ error ] error ) then + x
      # But without insertions, we get: ( [ error then + x
      assert length(error_tokens(tokens)) >= 1

      # Just verify it continues to tokenize + x
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> t == {:dual_op, elem(elem(t, 1), 0), :+} end)
    end

    test "unexpected end with continuation" do
      tokens = tokenize_tolerant("end\nfoo")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :identifier] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {_, _, :foo} = Enum.at(valid, 0)
    end

    test "unexpected end with hint" do
      # This tests indentation hints - should still continue
      tokens = tokenize_tolerant("do\n  :ok\n  end\nend")

      # Should have errors for indentation mismatch
      assert length(error_tokens(tokens)) >= 1

      # But should tokenize the :ok atom
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 0) == :atom and elem(t, 2) == :ok end)
    end
  end

  # ============================================================================
  # Category 5: Map Syntax Errors
  # ============================================================================

  describe "Category 5: Map syntax errors" do
    test "space between % and { with continuation" do
      tokens = tokenize_tolerant("% {} + foo")

      assert length(error_tokens(tokens)) == 1
      # Should emit %, error, {, }, +, foo
      assert types = token_types(tokens)
      assert :% in types
      assert :error_token in types
      assert :"{" in types
      assert :dual_op in types
      assert :identifier in types
    end

    test "invalid opener %( with continuation" do
      tokens = tokenize_tolerant("%( ) + x")

      assert length(error_tokens(tokens)) == 1
      assert types = token_types(tokens)
      assert :% in types
      assert :error_token in types
    end

    test "invalid opener %[ with continuation" do
      tokens = tokenize_tolerant("%[ ] , y")

      assert length(error_tokens(tokens)) == 1
      assert types = token_types(tokens)
      assert :% in types
      assert :error_token in types
    end
  end

  # ============================================================================
  # Category 6: Identifier & Keyword Errors
  # ============================================================================

  describe "Category 6: Identifier and keyword errors" do
    test "keyword not followed by space" do
      tokens = tokenize_tolerant("foo:bar + baz")

      assert length(error_tokens(tokens)) == 1
      # Should emit foo, error, bar, +, baz
      assert types = token_types(tokens)
      assert Enum.count(types, &(&1 == :identifier)) >= 2
      assert :error_token in types
      assert :dual_op in types
    end

    test "unexpected reserved word do after comma" do
      tokens = tokenize_tolerant("if true, do\n  :ok")

      assert length(error_tokens(tokens)) >= 1
      # Should continue and tokenize :ok
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 0) == :atom and elem(t, 2) == :ok end)
    end

    test "identifier with @ sign" do
      tokens = tokenize_tolerant("foo@bar + x")

      assert length(error_tokens(tokens)) >= 1
      # Should continue with + x
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 0) == :dual_op end)
    end

    test "empty identifier after colon" do
      tokens = tokenize_tolerant(": + foo")

      assert length(error_tokens(tokens)) == 1
      assert types = token_types(tokens)
      assert :error_token in types
      assert :dual_op in types
    end

    test "consecutive semicolons" do
      tokens = tokenize_tolerant("foo ;; bar")

      assert length(error_tokens(tokens)) == 1
      assert types = token_types(tokens)
      assert :identifier in types
      assert :";" in types
      assert :error_token in types
    end
  end

  # ============================================================================
  # Forward Progress and Position Tests
  # ============================================================================

  describe "Forward progress guarantees" do
    test "no infinite loop on repeated errors" do
      # Multiple errors in a row should all advance position
      tokens = tokenize_tolerant("<<<<<<< foo\n<<<<<<< bar\nqux")

      assert length(error_tokens(tokens)) == 2
      assert types = token_types(tokens)
      assert :identifier in types

      # Last token should be qux
      valid = valid_tokens(tokens)
      assert {_, _, :qux} = List.last(valid)

      assert_forward_progress(tokens)
    end

    test "error recovery reaches EOF" do
      # Even with errors, should reach EOF without hanging
      tokens = tokenize_tolerant("foo\0bar\0baz")

      assert length(error_tokens(tokens)) == 2
      assert length(valid_tokens(tokens)) == 3

      assert_forward_progress(tokens)
    end

    test "error at every position still completes" do
      # Pathological case: error on every char (if we feed invalid input)
      # This tests the max_skip fallback
      input = String.duplicate(<<0>>, 10) <> "ok"
      tokens = tokenize_tolerant(input)

      # Should get multiple errors, then successfully tokenize 'ok'
      assert length(error_tokens(tokens)) >= 1
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 2) == :ok end)

      assert_forward_progress(tokens)
    end

    test "position accuracy after error" do
      tokens = tokenize_tolerant("foo\nbar" <> <<0>> <> "\nbaz")

      # Error should be on line 2
      error = Enum.find(tokens, fn t -> elem(t, 0) == :error_token end)
      {_kind, {{_sl, _sc}, {el, _ec}, _extra}, _reason} = error

      # Error end line should be <= line of baz
      baz_token = Enum.find(tokens, fn t -> elem(t, 2) == :baz end)
      {_, {{baz_line, _}, _, _}, _} = baz_token

      assert el <= baz_line
    end
  end

  # ============================================================================
  # Deferral Preservation Tests
  # ============================================================================

  describe "Deferral preservation" do
    test "EOL before error is preserved" do
      tokens = tokenize_tolerant("foo\n" <> <<0>> <> "bar")

      # Should have: foo, eol, error, bar
      types = token_types(tokens)
      assert :identifier in types
      assert :eol in types
      assert :error_token in types

      # EOL should come before error token
      eol_idx = Enum.find_index(types, &(&1 == :eol))
      error_idx = Enum.find_index(types, &(&1 == :error_token))
      assert eol_idx < error_idx
    end

    test "semicolon before error" do
      tokens = tokenize_tolerant("x ; " <> <<0>> <> " y")

      types = token_types(tokens)
      assert :";" in types
      assert :error_token in types

      # Semicolon should come before error
      semi_idx = Enum.find_index(types, &(&1 == :";"))
      error_idx = Enum.find_index(types, &(&1 == :error_token))
      assert semi_idx < error_idx
    end
  end

  # ============================================================================
  # Sync Point Tests
  # ============================================================================

  describe "Sync point behavior" do
    test "sync to semicolon" do
      tokens = tokenize_tolerant("foo" <> <<0, 0, 0>> <> "; bar")

      # Error should stop before semicolon
      assert types = token_types(tokens)
      assert :";" in types

      # Semicolon should be valid token, not consumed by error
      semi = Enum.find(tokens, fn t -> elem(t, 0) == :";" end)
      assert semi != nil
    end

    test "sync to newline" do
      tokens = tokenize_tolerant("x" <> <<0, 0>> <> "\ny")

      # Error should stop before newline
      assert types = token_types(tokens)
      assert :eol in types
      assert :identifier in types

      # y should be on line 2
      y_token = Enum.find(tokens, fn t -> elem(t, 2) == :y end)
      {_, {{line, _}, _, _}, _} = y_token
      assert line == 2
    end

    test "sync to comma" do
      tokens = tokenize_tolerant("f(" <> <<0>> <> ", x)")

      # Error should stop before comma
      assert types = token_types(tokens)
      assert :"," in types
    end

    test "sync to comment" do
      tokens = tokenize_tolerant("foo" <> <<0>> <> "# comment\nbar")

      # Error should stop before #
      # Comment is discarded by default
      assert types = token_types(tokens)
      assert :identifier in types

      # bar should be tokenized
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 2) == :bar end)
    end

    test "sync to closer when in context" do
      tokens = tokenize_tolerant("(foo" <> <<0>> <> ")")

      # Error should stop before )
      assert types = token_types(tokens)
      assert :"(" in types
      assert :")" in types
    end
  end

  # ============================================================================
  # Continuation After Different Error Types
  # ============================================================================

  describe "Continuation after specific error types" do
    test "continue after alias error" do
      # Invalid char in alias
      tokens = tokenize_tolerant("Foo.Bär + Bar")

      assert length(error_tokens(tokens)) >= 1

      # Should tokenize Bar
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 2) == Bar end)
    end

    test "continue after sigil error" do
      # Invalid sigil name
      tokens = tokenize_tolerant("~zz(hello) + world")

      assert length(error_tokens(tokens)) >= 1

      # Should tokenize + world
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 0) == :dual_op end)
    end

    test "continue after ternary error" do
      tokens = tokenize_tolerant("..//foo + bar")

      assert length(error_tokens(tokens)) >= 1

      # Should continue with + bar
      valid = valid_tokens(tokens)
      assert Enum.any?(valid, fn t -> elem(t, 2) == :bar end)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "Edge cases" do
    test "error at very end of input" do
      tokens = tokenize_tolerant("foo + bar" <> <<0>>)

      assert length(error_tokens(tokens)) == 1
      assert length(valid_tokens(tokens)) == 3
    end

    test "only error tokens" do
      tokens = tokenize_tolerant(<<0, 0, 0>>)

      # Should get multiple errors, one for each byte
      assert length(error_tokens(tokens)) >= 1
    end

    test "error after all valid tokens processed" do
      tokens = tokenize_tolerant("x = 1; y = 2\n" <> <<0>>)

      # Should successfully tokenize all valid tokens
      valid = valid_tokens(tokens)
      assert length(valid) >= 6
    end

    test "mixed valid and invalid in single line" do
      tokens = tokenize_tolerant("a" <> <<0>> <> "b" <> <<0>> <> "c")

      assert length(error_tokens(tokens)) == 2
      assert length(valid_tokens(tokens)) == 3

      types = token_types(tokens)
      assert :identifier in types
      assert :error_token in types
    end
  end
end
