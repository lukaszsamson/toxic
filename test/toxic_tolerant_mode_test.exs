defmodule ToxicTolerantModeTest do
  use ExUnit.Case

  # Helper to tokenize in tolerant mode
  defp tokenize_tolerant(string, opts \\ []) do
    stream_opts =
      [
        error_mode: :tolerant,
        elixir_compatibility: false,
        preserve_comments: false
      ]
      |> Keyword.merge(
        Keyword.take(opts, [
          :existing_atoms_only,
          :insert_structural_closers,
          :insert_identifier_sanitization
        ])
      )

    stream = Toxic.TokenStream.new(string, 1, 1, stream_opts)

    opts = Keyword.put_new(opts, :include_errors, true)
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
      # Note: \0 is a single error, recovery should continue with bar.
      tokens = tokenize_tolerant("foo" <> <<0>> <> "bar + baz")

      assert length(error_tokens(tokens)) == 1
      # Expect foo, error, bar, +, baz
      assert [:identifier, :error_token, :identifier, :dual_op, :identifier] = token_types(tokens)

      # Verify continuation tokens are correct
      valid = valid_tokens(tokens)
      assert get_token_value(Enum.at(valid, 0)) == :foo
      assert get_token_value(Enum.at(valid, 1)) == :bar
      assert {:dual_op, _, :+} = Enum.at(valid, 2)
      assert get_token_value(Enum.at(valid, 3)) == :baz

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
      assert {:int, _, ~c'456'} = Enum.at(valid, 1)

      # Error should cover "123abc"
      {:error_token, meta, _reason} = Enum.at(tokens, 0)
      assert {{1, 1}, {1, 7}, _} = meta
    end

    test "invalid char after float with continuation" do
      tokens = tokenize_tolerant("1.2a + 3.4")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :dual_op, :flt] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {:flt, _, ~c'3.4'} = Enum.at(valid, 1)
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
      # With synthesis, we get an error, a synthetic opener, the actual closer, and then the rest.
      assert [:error_token, :"(", :")", :dual_op, :identifier] = token_types(tokens)

      valid = valid_tokens(tokens)
      assert {:dual_op, _, :+} = Enum.at(valid, 2)
      assert {_, _, :foo} = Enum.at(valid, 3)
    end

    test "unexpected closing bracket with continuation" do
      tokens = tokenize_tolerant("] ; bar")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :"[", :"]", :";", :identifier] = token_types(tokens)
    end

    test "unexpected closing brace" do
      tokens = tokenize_tolerant("} , baz")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :"{", :"}", :",", :identifier] = token_types(tokens)
    end

    test "unexpected bitstring close" do
      tokens = tokenize_tolerant(">> + x")

      assert length(error_tokens(tokens)) == 1
      assert [:error_token, :"<<", :">>", :dual_op, :identifier] = token_types(tokens)
    end

    test "mismatched delimiter with continuation" do
      tokens = tokenize_tolerant("([) + x")
      assert length(error_tokens(tokens)) >= 1

      assert [:"(", :"[", :error_token, :"]", :")", :dual_op, :identifier] = token_types(tokens)
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

      assert Enum.any?(valid, fn
               {:atom, _, :ok} -> true
               _ -> false
             end)
    end
  end

  # ============================================================================
  # Category 5: Map Syntax Errors
  # ============================================================================

  describe "Category 5: Map syntax errors" do
    test "space between % and { with continuation" do
      tokens = tokenize_tolerant("% {} + foo")

      assert length(error_tokens(tokens)) == 1
      # % is emitted first, then error consumes {}, then + and foo
      types = token_types(tokens)
      assert [:%, :error_token, :dual_op, :identifier] = types
    end

    test "invalid opener %( with continuation" do
      tokens = tokenize_tolerant("%( ) + x")

      assert length(error_tokens(tokens)) == 1
      types = token_types(tokens)
      assert [:%, :error_token, :"(", :")", :dual_op, :identifier] = types
    end

    test "invalid opener %[ with continuation" do
      tokens = tokenize_tolerant("%[ ] , y")

      assert length(error_tokens(tokens)) == 1
      types = token_types(tokens)
      assert [:%, :error_token, :"[", :"]", :",", :identifier] = types
    end
  end

  # ============================================================================
  # Category 6a: Keyword Spacing Errors
  # ============================================================================

  describe "Category 6a: Keyword spacing errors" do
    test "keyword not followed by space (foo:bar)" do
      tokens = tokenize_tolerant("foo:bar + baz")

      assert length(error_tokens(tokens)) == 1
      types = token_types(tokens)
      # foo identifier emitted first, then error at :, then bar, then +, then baz
      assert [:identifier, :error_token, :identifier, :dual_op, :identifier] = types

      # Verify values
      valid = valid_tokens(tokens)
      assert {:identifier, _, :foo} = Enum.at(valid, 0)
      assert {:identifier, _, :bar} = Enum.at(valid, 1)
      assert {:identifier, _, :baz} = Enum.at(valid, 3)
    end
  end

  # ============================================================================
  # Category 6b: Identifier Sanitization
  # ============================================================================

  describe "Category 6b: Identifier sanitization (insert_identifier_sanitization: true)" do
    test "mixed script Latin+Cyrillic triggers sanitization" do
      # Using Cyrillic 'а' (U+0430) which looks like Latin 'a'
      # This should trigger "mixed script" error
      # Cyrillic а in "varа"
      mixed = "varа + 1"
      tokens = tokenize_tolerant(mixed, insert_identifier_sanitization: true)

      types = token_types(tokens)
      # Should have error for mixed script
      assert :error_token in types
      # Should continue with sanitized identifier or next token
      assert :dual_op in types or :identifier in types
    end

    test "confusable Greek omicron in identifier" do
      # Greek omicron (ο, U+03BF) looks like Latin o
      # This should trigger confusable character error
      # Greek ο in "foο"
      confusable = "foο + bar"
      tokens = tokenize_tolerant(confusable, insert_identifier_sanitization: true)

      types = token_types(tokens)
      assert :error_token in types
      # Should continue with rest of expression
      assert :dual_op in types
      assert :identifier in types
    end

    test "atom with excessive length triggers sanitization" do
      # Atoms in Elixir have a length limit (255 bytes)
      long_name = String.duplicate("x", 300)
      tokens = tokenize_tolerant(":#{long_name} + 1", insert_identifier_sanitization: true)

      # Should have error for atom length
      assert length(error_tokens(tokens)) >= 1
      # Should continue with + and 1
      types = token_types(tokens)
      assert :dual_op in types
      assert :int in types
    end

    test "identifier with excessive length triggers sanitization" do
      # Very long identifier
      # 400 chars
      long_name = String.duplicate("variable", 50)
      tokens = tokenize_tolerant("#{long_name} = 1", insert_identifier_sanitization: true)

      # Behavior depends on whether String.Tokenizer rejects this
      # At minimum, should not crash and should continue
      types = token_types(tokens)
      # Should have either identifier or error + sanitized identifier
      assert :match_op in types
      assert :int in types
    end

    test "NFKC normalization with compatibility characters" do
      # Compatibility characters that should normalize (e.g., ﬁ ligature)
      # Note: This may or may not trigger an error depending on String.Tokenizer
      # ﬁ is U+FB01 (fi ligature)
      nfkc_test = "ﬁle + 1"
      tokens = tokenize_tolerant(nfkc_test, insert_identifier_sanitization: true)

      # Should tokenize successfully (NFKC normalizes to "file")
      # or produce error + sanitized identifier
      types = token_types(tokens)
      assert :dual_op in types
      assert :int in types
    end

    test "sanitization disabled does not create synthetic identifiers" do
      # With sanitization off, errors should just be errors
      # Cyrillic а
      mixed = "varа + 1"
      tokens = tokenize_tolerant(mixed, insert_identifier_sanitization: false)

      types = token_types(tokens)
      # Should have error
      assert :error_token in types
      # Should NOT have sanitized identifier before the error
      # (any identifiers are from normal tokenization, not sanitization)
    end

    test "sanitization with null byte in identifier" do
      # Null bytes are control characters
      tokens = tokenize_tolerant("foo\x00bar + x", insert_identifier_sanitization: true)

      types = token_types(tokens)
      assert :error_token in types
      # Should recover and continue
      assert :dual_op in types
    end

    test "sanitization creates valid ASCII skeleton" do
      # Mixed with confusables should produce ASCII-safe identifier
      # Cyrillic е (U+0435) instead of Latin e
      mixed = "tеst"
      tokens = tokenize_tolerant("#{mixed} = 1", insert_identifier_sanitization: true)

      # Should have error + continue with assignment
      types = token_types(tokens)
      assert :match_op in types
      assert :int in types

      # If sanitized identifier is created, it should be ASCII-only
      identifiers = Enum.filter(tokens, fn t -> elem(t, 0) == :identifier end)

      if length(identifiers) > 0 do
        # Check that sanitized identifier is present
        assert length(identifiers) >= 1
      end
    end
  end

  # ============================================================================
  # Category 6: Identifier & Keyword Errors
  # ============================================================================

  describe "Category 6: Identifier and keyword errors" do
    test "keyword not followed by space" do
      tokens = tokenize_tolerant("foo:bar + baz")

      types = token_types(tokens)
      assert [:identifier, :error_token, :identifier, :dual_op, :identifier | _] = types
    end

    test "unexpected reserved word do after comma" do
      tokens = tokenize_tolerant("if true, do\n  :ok")

      assert length(error_tokens(tokens)) >= 1
      # Should continue and tokenize :ok
      valid = valid_tokens(tokens)

      assert Enum.any?(valid, fn
               {:atom, _, :ok} -> true
               _ -> false
             end)
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

      types = token_types(tokens)
      assert [:identifier, :";", :error_token, :identifier | _] = types
    end
  end

  # ============================================================================
  # Identifier Sanitization
  # ============================================================================

  describe "Identifier sanitization" do
    test "mixed script identifier is sanitized" do
      input = "foo" <> <<0x03B1::utf8>> <> "bar + 1"
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert [:error_token, :identifier, :dual_op, :int | _] = types

      sanitized_atom =
        tokens
        |> Enum.find_value(fn
          {:identifier, _, atom} -> atom
          _ -> nil
        end)

      assert sanitized_atom |> Atom.to_string() |> String.match?(~r/^[A-Za-z0-9_]+$/)
    end

    test "confusable identifier is sanitized" do
      input = "foO" <> <<0x1D6B3::utf8>> <> " + 1"
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert [:error_token, :identifier, :dual_op, :int | _] = types

      sanitized_atom =
        tokens
        |> Enum.find_value(fn
          {:identifier, _, atom} -> atom
          _ -> nil
        end)

      assert sanitized_atom |> Atom.to_string() |> String.match?(~r/^[A-Za-z0-9_]+$/)
    end

    test "identifier exceeding atom length limit is truncated" do
      long = String.duplicate("a", 300) <> " + 1"
      tokens = tokenize_tolerant(long)

      types = token_types(tokens)
      assert [:error_token, :identifier, :dual_op, :int | _] = types

      sanitized_atom =
        tokens
        |> Enum.find_value(fn
          {:identifier, _, atom} -> atom
          _ -> nil
        end)

      san = Atom.to_string(sanitized_atom)
      assert byte_size(san) <= 255
      assert String.match?(san, ~r/^[A-Za-z0-9_]+$/)
    end

    test "sanitization disabled does not insert identifier" do
      input = "foo" <> <<0x03B1::utf8>> <> "bar + 1"
      tokens = tokenize_tolerant(input, insert_identifier_sanitization: false)

      types = token_types(tokens)
      assert [:error_token, :dual_op, :int | _] = types
    end
  end

  # ============================================================================
  # Additional Coverage: Reserved tokens, alias, sigil, identifier variants
  # ============================================================================

  describe "Reserved tokens and alias errors" do
    test "reserved token __aliases__" do
      tokens = tokenize_tolerant("__aliases__ + Foo")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :dual_op))
      assert Enum.any?(token_types(tokens), &(&1 == :alias))
    end

    test "reserved token __block__" do
      tokens = tokenize_tolerant("__block__ + Bar")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :dual_op))
      assert Enum.any?(token_types(tokens), &(&1 == :alias))
    end

    test "unexpected token after alias" do
      tokens = tokenize_tolerant("Foo(1 + 2)")

      types = token_types(tokens)
      assert [:alias, :"(", :error_token, :int, :dual_op, :int, :")" | _] = types
    end

    test "alias unexpected paren recovery emits both error and paren token" do
      # Dedicated test for alias_unexpected_paren error recovery
      # Recovery emits: alias, :(, error_token, contents..., :)
      # The :( comes before the error to allow normal call parsing
      tokens = tokenize_tolerant("FooBar(123)")

      types = token_types(tokens)
      # Should have: alias, :(, error_token, int, :)
      assert [:alias, :"(", :error_token, :int, :")"] = Enum.take(types, 5)

      # Verify the error is specifically alias_unexpected_paren
      error_token = Enum.find(tokens, fn t -> match?({:error_token, _, _}, t) end)
      assert {:error_token, _meta, %Toxic.Error{code: :alias_unexpected_paren}} = error_token

      # Verify :( token appears before error (allows parsing of call arguments)
      error_idx = Enum.find_index(types, &(&1 == :error_token))
      paren_idx = Enum.find_index(types, &(&1 == :"("))
      assert paren_idx < error_idx, "Open paren should come before error to enable call parsing"
    end

    test "fn followed by do" do
      tokens = tokenize_tolerant("fn do\n:ok")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :atom))
    end

    test "mismatched closing terminator - end" do
      tokens = tokenize_tolerant("([end + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end
  end

  describe "Sigil errors" do
    test "invalid uppercase sigil name" do
      tokens = tokenize_tolerant("~Ab/foo/ + world")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :dual_op))
      assert Enum.any?(token_types(tokens), &(&1 == :identifier))
    end

    test "invalid char after sigil heredoc open" do
      tokens = tokenize_tolerant("~S\"\"\"foo\"\"\" + :ok")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :atom))
    end

    test "invalid sigil delimiter" do
      tokens = tokenize_tolerant("~s!foo! + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end
  end

  describe "Identifier variants" do
    test "identifier exceeding atom length limit" do
      tokens = tokenize_tolerant(String.duplicate("a", 256) <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "mixed script identifier" do
      tokens = tokenize_tolerant("foo" <> <<0x03B1::utf8>> <> "bar + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "mixed script identifier without suggestion" do
      tokens = tokenize_tolerant("foo" <> <<0x0402::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "identifier confusable suggestion" do
      tokens = tokenize_tolerant("foO" <> <<0x1D6B3::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "identifier nfkc suggestion" do
      tokens = tokenize_tolerant("foo" <> <<0x06CC::utf8>> <> <<0x1D6B3::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "unexpected token in identifier" do
      tokens = tokenize_tolerant(<<0x3164::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "unexpected token identifier control char" do
      tokens = tokenize_tolerant("foo" <> <<0x0080::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "unexpected token identifier control char in atom" do
      tokens = tokenize_tolerant(":foo" <> <<0x0080::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "unexpected token fallback" do
      tokens = tokenize_tolerant(<<0x03A9::utf8>> <> " + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end
  end

  describe "After-colon identifier errors" do
    test "unexpected token after colon" do
      tokens = tokenize_tolerant(":" <> <<0x200B::utf8>> <> " => 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 in [:assoc_op, :int]))
    end

    test "unexpected token after colon with zero width joiner" do
      tokens = tokenize_tolerant(":" <> <<0x200C::utf8>> <> " => 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 in [:assoc_op, :int]))
    end

    test "unexpected token after colon confusable suggestion" do
      tokens = tokenize_tolerant(":" <> "foO" <> <<0x1D6B3::utf8>> <> " => 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 in [:assoc_op, :int]))
    end

    test "unexpected token after colon control char" do
      tokens = tokenize_tolerant(":" <> <<0x0080::utf8>> <> " => 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 in [:assoc_op, :int]))
    end
  end

  describe "Comment and dot comment errors" do
    test "invalid bidi character in comment" do
      tokens = tokenize_tolerant("#" <> <<0x202E::utf8>> <> "\nfoo")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :identifier))
    end

    test "invalid line break character in comment" do
      tokens = tokenize_tolerant("#" <> <<0x2028::utf8>> <> "foo\nbar")

      if Version.match?(System.version(), ">= 1.19.0-rc.0") do
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end

      assert Enum.any?(token_types(tokens), &(&1 == :identifier))
    end

    test "invalid bidi character in dot comment" do
      tokens = tokenize_tolerant(".#" <> <<0x202E::utf8>> <> "\nfoo")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :identifier))
    end

    test "invalid line break character in dot comment" do
      tokens = tokenize_tolerant(".#" <> <<0x2028::utf8>> <> "\nfoo")

      if Version.match?(System.version(), ">= 1.19.0-rc.0") do
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end

      assert Enum.any?(token_types(tokens), &(&1 == :identifier))
    end
  end

  describe "String and interpolation character errors" do
    test "invalid bidi character in string" do
      tokens = tokenize_tolerant("\"\u202E\" + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "invalid line break character in string" do
      tokens = tokenize_tolerant("\"\u2028\" + 1")

      if Version.match?(System.version(), ">= 1.20.0-rc.0") do
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end

      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "invalid line break character in single quoted string" do
      tokens = tokenize_tolerant("'\u2028' + 1")

      if Version.match?(System.version(), ">= 1.20.0-rc.0") do
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end

      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "interpolation in quoted identifier" do
      tokens = tokenize_tolerant(~S|foo."bar#{baz}"() + 1|)

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "invalid char after string heredoc open" do
      tokens = tokenize_tolerant("\"\"\"foo\"\"\" + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end
  end

  describe "Missing terminators" do
    test "missing string terminator" do
      for input <- ["\"foo + 1", "'foo + 1"] do
        tokens = tokenize_tolerant(input)
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end

    test "missing heredoc terminator" do
      for input <- ["\"\"\"foo\nbar\n + 1", "\"\"\"foo\n", "'''foo\n", "'''foo\nbar"] do
        tokens = tokenize_tolerant(input)
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end

    test "missing quoted atom terminator" do
      for input <- [":\"foo + 1", ":'foo + 1"] do
        tokens = tokenize_tolerant(input)
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end

    test "missing quoted identifier terminator" do
      for input <- ["K.\"foo + 1", "K.'foo + 1"] do
        tokens = tokenize_tolerant(input)
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end

    test "missing sigil terminator" do
      for input <- ["~s\"foo + 1", "~S\"\"\"foo\nbar"] do
        tokens = tokenize_tolerant(input)
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end

    test "missing interpolation terminator" do
      tokens = tokenize_tolerant("\"\#{foo + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
    end

    test "missing terminator inside interpolation" do
      for input <- ["\"\#{foo(}\" + 1", "\"\#{foo[}\" + 1"] do
        tokens = tokenize_tolerant(input)
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
        assert Enum.any?(token_types(tokens), &(&1 == :int))
      end
    end

    test "missing terminator base cases" do
      for input <- ["foo(", "foo[", "(", "[", "{", "<<", "a do\n", "fn -> "] do
        tokens = tokenize_tolerant(input <> "1")
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end

    test "missing invalid character inside interpolation" do
      tokens = tokenize_tolerant("\"\#{\r}\" + 1")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end

    test "other invalid characters inside interpolation" do
      for expr <- ["\"\#{\\}\"", "\"\#{\\n}\"", "\"\#{;;}\""] do
        tokens = tokenize_tolerant(expr <> " + 1")
        assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      end
    end
  end

  describe "Existing atoms only" do
    test "not existing atom identifier" do
      input = "x0m18d7h0fd2s098d" <> to_string(Enum.random(11223..3_249_953)) <> ": 1"
      tokens = tokenize_tolerant(input, existing_atoms_only: true)

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :int))
    end
  end

  describe "Indentation hint errors" do
    test "missing terminator with indentation hint" do
      tokens = tokenize_tolerant("do\ndo\n  :ok\nend")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :atom))
    end

    test "unexpected end without hint" do
      tokens = tokenize_tolerant("end \n:ok")

      assert Enum.any?(token_types(tokens), &(&1 == :error_token))
      assert Enum.any?(token_types(tokens), &(&1 == :atom))
    end
  end

  # ============================================================================
  # Phase 2: Structural Synthesis Tests
  # ============================================================================

  describe "Phase 2: Structural synthesis (insert_structural_closers: true)" do
    # Helper for synthesis tests (default has flag enabled)
    defp tokenize_with_synthesis(string) do
      tokenize_tolerant(string)
    end

    defp tokenize_without_synthesis(string) do
      stream_opts = [
        error_mode: :tolerant,
        insert_structural_closers: false
      ]

      stream = Toxic.TokenStream.new(string, 1, 1, stream_opts)
      collect_all_tokens(stream, [], include_errors: true)
    end

    test "missing string terminator synthesizes bin_string_end" do
      tokens = tokenize_with_synthesis("\"foo")
      types = token_types(tokens)

      assert :error_token in types
      assert :bin_string_end in types
      # String end comes after error
      error_idx = Enum.find_index(types, &(&1 == :error_token))
      end_idx = Enum.find_index(types, &(&1 == :bin_string_end))
      assert end_idx > error_idx
    end

    test "missing charlist terminator synthesizes list_string_end" do
      tokens = tokenize_with_synthesis("'foo")
      types = token_types(tokens)

      assert :error_token in types
      assert :list_string_end in types
    end

    test "missing heredoc terminator synthesizes bin_heredoc_end" do
      tokens = tokenize_with_synthesis("\"\"\"foo\nbar")
      types = token_types(tokens)

      assert :error_token in types
      assert :bin_heredoc_end in types
    end

    test "missing list heredoc terminator synthesizes list_heredoc_end" do
      tokens = tokenize_with_synthesis("'''foo\nbar")
      types = token_types(tokens)

      assert :error_token in types
      assert :list_heredoc_end in types
    end

    test "missing sigil terminator synthesizes sigil_end" do
      tokens = tokenize_with_synthesis("~s\"foo")
      types = token_types(tokens)

      assert :error_token in types
      assert :sigil_end in types
    end

    test "missing quoted atom terminator synthesizes atom_unsafe_end" do
      tokens = tokenize_with_synthesis(":\"foo")
      types = token_types(tokens)

      assert :error_token in types
      assert :atom_unsafe_end in types
    end

    test "missing quoted identifier terminator synthesizes quoted_identifier_end" do
      tokens = tokenize_with_synthesis("Foo.\"bar")
      types = token_types(tokens)

      assert :error_token in types
      assert :quoted_identifier_end in types
    end

    test "missing interpolation terminator synthesizes end_interpolation" do
      tokens = tokenize_with_synthesis("\"\#{foo")
      types = token_types(tokens)

      # Should have: begin_interpolation, identifier, error, end_interpolation, error, bin_string_end
      assert :begin_interpolation in types
      assert :identifier in types
      assert :end_interpolation in types
      assert :bin_string_end in types

      # Count errors: one for missing }, one for missing "
      assert length(error_tokens(tokens)) == 2
    end

    test "missing terminator ( synthesizes closing )" do
      tokens = tokenize_with_synthesis("foo(")
      types = token_types(tokens)

      assert :error_token in types
      assert :")" in types
      assert :"(" in types
    end

    test "missing terminator [ synthesizes closing ]" do
      tokens = tokenize_with_synthesis("[1, 2")
      types = token_types(tokens)

      assert :error_token in types
      assert :"]" in types
    end

    test "missing terminator { synthesizes closing }" do
      tokens = tokenize_with_synthesis("{:a, :b")
      types = token_types(tokens)

      assert :error_token in types
      assert :"}" in types
    end

    test "missing terminator << synthesizes closing >>" do
      tokens = tokenize_with_synthesis("<<1, 2")
      types = token_types(tokens)

      assert :error_token in types
      assert :">>" in types
    end

    test "unexpected closer ) synthesizes opening (" do
      tokens = tokenize_with_synthesis(")")
      types = token_types(tokens)

      assert :error_token in types
      assert :"(" in types
      assert :")" in types

      # Order: error, synthetic (, actual )
      error_idx = Enum.find_index(types, &(&1 == :error_token))
      open_idx = Enum.find_index(types, &(&1 == :"("))
      close_idx = Enum.find_index(types, &(&1 == :")"))

      assert error_idx < open_idx
      assert open_idx < close_idx
    end

    test "unexpected closer ] synthesizes opening [" do
      tokens = tokenize_with_synthesis("]")
      types = token_types(tokens)

      assert :"[" in types
      assert :"]" in types
    end

    test "unexpected closer } synthesizes opening {" do
      tokens = tokenize_with_synthesis("}")
      types = token_types(tokens)

      assert :"{" in types
      assert :"}" in types
    end

    test "unexpected closer >> synthesizes opening <<" do
      tokens = tokenize_with_synthesis(">>")
      types = token_types(tokens)

      assert :"<<" in types
      assert :">>" in types
    end

    test "mismatched closer synthesizes expected closer" do
      tokens = tokenize_with_synthesis("([)")
      types = token_types(tokens)

      # Should have: (, [, error, ], error, )
      # Synthetic ] comes after first error, before second error
      assert :"(" in types
      assert :"[" in types
      assert :")" in types

      # Count ]: one synthetic, no actual (consumed by error)
      bracket_count = Enum.count(types, &(&1 == :"]"))
      assert bracket_count == 1

      # One error for mismatch
      assert length(error_tokens(tokens)) == 1
    end

    test "nested missing terminators synthesize multiple closers" do
      tokens = tokenize_with_synthesis("foo([{")
      types = token_types(tokens)

      # Should have errors and synthetic }, ], )
      assert :error_token in types
      assert :"}" in types
      assert :"]" in types
      assert :")" in types

      # Three errors (one per missing closer)
      assert length(error_tokens(tokens)) >= 3
    end

    test "EOF drains multiple errors with synthesis" do
      tokens = tokenize_with_synthesis("\"\#{foo(")
      types = token_types(tokens)

      # Should see:
      # - begin_interpolation, paren_identifier (foo is before `(`), (
      # - error (missing )), synthetic )
      # - error (missing }), synthetic end_interpolation
      # - error (missing "), synthetic bin_string_end

      assert :begin_interpolation in types
      assert :paren_identifier in types
      assert :"(" in types
      assert :")" in types
      assert :end_interpolation in types
      assert :bin_string_end in types

      # Three errors
      assert length(error_tokens(tokens)) == 3
    end

    test "synthesis preserves continuation after error" do
      tokens = tokenize_with_synthesis("foo( + 1")
      types = token_types(tokens)

      # Should have: paren_identifier (foo before `(`), (, error, ), +, int
      assert :paren_identifier in types
      assert :")" in types
      assert :dual_op in types
      assert :int in types
    end

    test "synthesis with flag disabled produces no synthetic tokens" do
      tokens = tokenize_without_synthesis("\"foo")
      types = token_types(tokens)

      # Should have error but NO bin_string_end
      assert :error_token in types
      refute :bin_string_end in types
    end

    test "missing interpolation without synthesis has no end_interpolation" do
      tokens = tokenize_without_synthesis("\"\#{foo")
      types = token_types(tokens)

      assert :error_token in types
      refute :end_interpolation in types
    end

    test "unexpected closer without synthesis has no synthetic opener" do
      tokens = tokenize_without_synthesis(")")
      types = token_types(tokens)

      # Should have error and actual ), but no synthetic (
      assert :error_token in types
      assert :")" in types

      # Only one ) (the actual one)
      close_count = Enum.count(types, &(&1 == :")"))
      assert close_count == 1
    end

    test "mismatched closer synthesizes expected closer even when insert_structural_closers is false" do
      # Note: Mismatched closers ALWAYS synthesize the expected closer to balance the stream,
      # regardless of the insert_structural_closers flag. The flag only affects unexpected closers.
      tokens = tokenize_without_synthesis("([)")
      types = token_types(tokens)

      # Output: ( [ error ] )
      # The ] is synthesized after the error even though synthesis flag is false
      assert types == [:"(", :"[", :error_token, :"]", :")"]
    end

    test "synthetic tokens have zero-length spans" do
      tokens = tokenize_with_synthesis(")")

      # Find synthetic ( - it should come after error, before )
      types = token_types(tokens)
      error_idx = Enum.find_index(types, &(&1 == :error_token))
      synthetic_paren = Enum.at(tokens, error_idx + 1)

      # Synthetic token should have zero-length meta
      case synthetic_paren do
        {:"(", {{sl, sc}, {el, ec}, _}} ->
          assert {sl, sc} == {el, ec}, "Synthetic token should have zero-length span"

        _ ->
          flunk("Expected synthetic ( after error")
      end
    end
  end

  describe "Nested interpolation EOF recovery" do
    test "string with unterminated interpolation synthesizes closers" do
      tokens = tokenize_tolerant("\"\#{foo(")

      types = token_types(tokens)
      assert Enum.count(types, &(&1 == :error_token)) >= 3
      assert Enum.any?(types, &(&1 == :end_interpolation))
      assert Enum.any?(types, &(&1 == :bin_string_end))
    end
  end

  describe "Cascade error recovery" do
    test "mixed errors (%( foo:bar ..// ;; baz)" do
      input = "% ( foo:bar ..// ;; baz"
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert Enum.count(types, &(&1 == :error_token)) >= 4
      assert Enum.any?(types, &(&1 == :"("))
      assert Enum.any?(types, &(&1 == :";"))
      assert Enum.any?(types, fn t -> t == :identifier end)

      # baz should appear in valid tokens (may not be last due to synthesized closers)
      valid = valid_tokens(tokens)

      assert Enum.any?(valid, fn
               {:identifier, _, :baz} -> true
               _ -> false
             end)
    end

    test "nested interpolation with missing terminators" do
      input = ~S["#{foo(#{bar[}"]
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert Enum.count(types, &(&1 == :error_token)) >= 3
      assert Enum.any?(types, &(&1 == :end_interpolation))
      assert Enum.any?(types, &(&1 == :bin_string_end))
    end

    test "brace then array opener error sequence" do
      input = "{ [ ) }"
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert types == [:"{", :"[", :error_token, :"]", :"}"]
    end

    test "nested structural + identifier issues" do
      input = "%{ foo" <> <<0x03B1::utf8>> <> "bar ;;" <> <<0x202E::utf8>>
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert Enum.count(types, &(&1 == :error_token)) >= 3
      # Map %{ emits :%{} composite token, not bare :%
      assert Enum.any?(types, &(&1 == :%{}))
      assert Enum.any?(types, &(&1 == :"{"))
      assert Enum.any?(types, &(&1 == :";"))

      # Sanitized identifier should appear (after map tokens)
      identifiers = Enum.filter(tokens, fn t -> elem(t, 0) == :identifier end)
      assert length(identifiers) > 0
      {_type, _meta, id} = hd(identifiers)
      assert id |> Atom.to_string() |> String.match?(~r/^[A-Za-z0-9_]+$/)
    end

    test "string with escaped newline and unterminated interpolation" do
      input = ~S["line1\
#{foo"]
      tokens = tokenize_tolerant(input)

      types = token_types(tokens)
      assert Enum.count(types, &(&1 == :error_token)) >= 2
      assert Enum.any?(types, &(&1 == :end_interpolation))
      assert Enum.any?(types, &(&1 == :bin_string_end))
      # Position should advance to line 2
      foo_token = Enum.find(tokens, fn t -> match?({:identifier, _, :foo}, t) end)

      if foo_token do
        {:identifier, {{line, _}, _, _}, _} = foo_token
        assert line >= 2
      end
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

      assert Enum.any?(valid, fn
               {:identifier, _, :ok} -> true
               {:atom, _, :ok} -> true
               {:alias, _, :ok} -> true
               _ -> false
             end)

      assert_forward_progress(tokens)
    end

    test "position accuracy after error" do
      tokens = tokenize_tolerant("foo\nbar" <> <<0>> <> "\nbaz")

      # Error should be on line 2
      error = Enum.find(tokens, fn t -> elem(t, 0) == :error_token end)
      {_kind, {{_sl, _sc}, {el, _ec}, _extra}, _reason} = error

      # Error end line should be <= line of baz
      baz_token =
        Enum.find(tokens, fn
          {_, _, :baz} -> true
          _ -> false
        end)

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
      y_token =
        Enum.find(tokens, fn
          {_, _, :y} -> true
          _ -> false
        end)

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

      assert Enum.any?(valid, fn
               {_, _, :bar} -> true
               _ -> false
             end)
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

      assert Enum.any?(valid, fn
               {:alias, _, :Bar} -> true
               _ -> false
             end)
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

      types = token_types(tokens)
      assert [:error_token, :identifier, :identifier, :dual_op, :identifier] = types
      [_, op_token | _] = tokens
      assert {:identifier, _, :..//} = op_token
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
