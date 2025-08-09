defmodule ToxicTest do
  use ExUnit.Case
  doctest Toxic

  defp tokenize(string) do
    charlist = to_charlist(string)
    {:ok, _, _, _, toxic_tokens_with_ranges, toxic_remaining} =
      :toxic_tokenizer.tokenize_with_ranges(charlist, 1, 1, [])

    # Convert back to legacy format for comparison
    toxic_tokens = :toxic_tokenizer.ranges_to_legacy(toxic_tokens_with_ranges)

    {:ok, _, _, _, elixir_tokens, _remaining} =
      :elixir_tokenizer.tokenize(charlist, 1, 1, [])

    assert Enum.reverse(toxic_tokens) == Enum.reverse(elixir_tokens)

    tokens = Enum.reverse(toxic_tokens_with_ranges)
    remaining_str = List.to_string(toxic_remaining)

    {:ok, tokens, remaining_str}
  end

  test "empty" do
    assert tokenize("") == {:ok, [], ""}
  end

  describe "tokenize_with_ranges" do
    test "returns tokens with end positions" do
      {:ok, _, _, _, tokens, _} =
        :toxic_tokenizer.tokenize_with_ranges(to_charlist("0x123"), 1, 1, [])

      # Check that we got a token with range format
      assert [{:int, {{1, 1}, {1, 6}, _}, ~c"0x123"}] = Enum.reverse(tokens)
    end

    test "multi-token expression has correct ranges" do
      {:ok, _, _, _, tokens, _} =
        :toxic_tokenizer.tokenize_with_ranges(to_charlist("0x123;"), 1, 1, [])

      reversed = Enum.reverse(tokens)

      # Check we got the expected tokens with ranges
      assert [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"},
              {:";", {{1, 6}, {1, 7}, 0}}] = reversed
    end

    test "ranges_to_legacy converts correctly" do
      {:ok, _, _, _, tokens_with_ranges, _} =
        :toxic_tokenizer.tokenize_with_ranges(to_charlist("0x123"), 1, 1, [])

      legacy_tokens = :toxic_tokenizer.ranges_to_legacy(tokens_with_ranges)

      # Should match the legacy format
      assert [{:int, {1, 1, _}, ~c"0x123"}] = Enum.reverse(legacy_tokens)
    end
  end

  describe "hex numbers" do
    test "simple hex numbers" do
      assert tokenize("0x123") == {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}], ""}
    end

    test "hex numbers with underscores" do
      assert tokenize("0xAB_CD") == {:ok, [{:int, {{1, 1}, {1, 8}, 43981}, ~c"0xAB_CD"}], ""}
    end

    test "hex numbers with uppercase and lowercase" do
      assert tokenize("0xAbCd") == {:ok, [{:int, {{1, 1}, {1, 7}, 43981}, ~c"0xAbCd"}], ""}
    end

    test "hex followed by other characters" do
      assert tokenize("0x123;") == {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}, {:";", {{1, 6}, {1, 7}, 0}}], ""}
    end
  end

  describe "binary numbers" do
    test "simple binary numbers" do
      assert tokenize("0b101") == {:ok, [{:int, {{1, 1}, {1, 6}, 5}, ~c"0b101"}], ""}
    end

    test "binary numbers with underscores" do
      assert tokenize("0b10_10_01") == {:ok, [{:int, {{1, 1}, {1, 11}, 41}, ~c"0b10_10_01"}], ""}
    end

    test "binary followed by other characters" do
      assert tokenize("0b1010;") == {:ok, [{:int, {{1, 1}, {1, 7}, 10}, ~c"0b1010"}, {:";", {{1, 7}, {1, 8}, 0}}], ""}
    end
  end

  describe "octal numbers" do
    test "simple octal numbers" do
      assert tokenize("0o123") == {:ok, [{:int, {{1, 1}, {1, 6}, 83}, ~c"0o123"}], ""}
    end

    test "octal numbers with underscores" do
      assert tokenize("0o12_34_56") == {:ok, [{:int, {{1, 1}, {1, 11}, 42798}, ~c"0o12_34_56"}], ""}
    end

    test "octal followed by other characters" do
      assert tokenize("0o765;") == {:ok, [{:int, {{1, 1}, {1, 6}, 501}, ~c"0o765"}, {:";", {{1, 6}, {1, 7}, 0}}], ""}
    end
  end

  describe "floats" do
    test "simple floats" do
      assert tokenize("1.23") == {:ok, [{:flt, {{1, 1}, {1, 5}, 1.23}, ~c"1.23"}], ""}
    end

    test "floats with underscores" do
      assert tokenize("1_2_3.4_5") == {:ok, [{:flt, {{1, 1}, {1, 10}, 123.45}, ~c"1_2_3.4_5"}], ""}
    end

    test "floats with leading 0" do
      assert tokenize("01.123") == {:ok, [{:flt, {{1, 1}, {1, 7}, 1.123}, ~c"01.123"}], ""}
    end

    test "floats with exponent" do
      assert tokenize("1.23e4") == {:ok, [{:flt, {{1, 1}, {1, 7}, 12300.0}, ~c"1.23e4"}], ""}
      assert tokenize("1.23E4") == {:ok, [{:flt, {{1, 1}, {1, 7}, 12300.0}, ~c"1.23E4"}], ""}
    end

    test "floats with e and underscore" do
      assert tokenize("1_2_3.4_5e6_7") ==
               {:ok, [{:flt, {{1, 1}, {1, 14}, 1.2345e69}, ~c"1_2_3.4_5e6_7"}], ""}
    end

    test "floats with e and underscore and sign" do
      assert tokenize("1_2_3.4_5e-6_7") ==
               {:ok, [{:flt, {{1, 1}, {1, 15}, 1.2345e-65}, ~c"1_2_3.4_5e-6_7"}], ""}

      assert tokenize("1_2_3.4_5e+6_7") ==
               {:ok, [{:flt, {{1, 1}, {1, 15}, 1.2345e69}, ~c"1_2_3.4_5e+6_7"}], ""}
    end

    test "floats followed by other characters" do
      assert tokenize("1.23;") == {:ok, [{:flt, {{1, 1}, {1, 5}, 1.23}, ~c"1.23"}, {:";", {{1, 5}, {1, 6}, 0}}], ""}
    end
  end

  describe "integers" do
    test "simple integers" do
      assert tokenize("123") == {:ok, [{:int, {{1, 1}, {1, 4}, 123}, ~c"123"}], ""}
    end

    test "starting with 0" do
      assert tokenize("0123") == {:ok, [{:int, {{1, 1}, {1, 5}, 123}, ~c"0123"}], ""}
    end

    test "integers with underscores" do
      assert tokenize("1_2_3") == {:ok, [{:int, {{1, 1}, {1, 6}, 123}, ~c"1_2_3"}], ""}
    end

    test "integers followed by other characters" do
      assert tokenize("123;") == {:ok, [{:int, {{1, 1}, {1, 4}, 123}, ~c"123"}, {:";", {{1, 4}, {1, 5}, 0}}], ""}
    end
  end

  describe "operator atoms" do
    test "keyword identifiers" do
      assert tokenize(".: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 3}, nil}, :.}], ""}
      assert tokenize("<<>>: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 6}, nil}, :<<>>}], ""}
      assert tokenize("%{}: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 5}, nil}, :%{}}], ""}
      assert tokenize("%: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 3}, nil}, :%}], ""}
      assert tokenize("&: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 3}, nil}, :&}], ""}
      assert tokenize("{}: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 4}, nil}, :{}}], ""}
      assert tokenize("..//: ") == {:ok, [{:kw_identifier, {{1, 1}, {1, 6}, nil}, :..//}], ""}
    end

    test "atom operators" do
      assert tokenize(":<<>>") == {:ok, [{:atom, {{1, 1}, {1, 6}, nil}, :<<>>}], ""}
      assert tokenize(":%{}") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :%{}}], ""}
      assert tokenize(":%") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :%}], ""}
      assert tokenize(":{}") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :{}}], ""}
      assert tokenize(":..//") == {:ok, [{:atom, {{1, 1}, {1, 6}, nil}, :..//}], ""}
    end

    test "atoms followed by other characters" do
      assert tokenize(":%{};") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :%{}}, {:";", {{1, 5}, {1, 6}, 0}}], ""}
    end
  end

  describe "operators as atoms" do
    test "three-token operators as atoms" do
      # unary_op3
      assert tokenize(":~~~") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :"~~~"}], ""}
      # comp_op3
      assert tokenize(":===") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :===}], ""}
      assert tokenize(":!==") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :!==}], ""}
      # and_op3
      assert tokenize(":&&&") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :&&&}], ""}
      # or_op3
      assert tokenize(":|||") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :|||}], ""}
      # arrow_op3
      assert tokenize(":<<<") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :<<<}], ""}
      assert tokenize(":>>>") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :>>>}], ""}
      assert tokenize(":~>>") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :~>>}], ""}
      assert tokenize(":<<~") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :<<~}], ""}
      assert tokenize(":<~>") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :<~>}], ""}
      assert tokenize(":<|>") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :"<|>"}], ""}
      # xor_op3
      assert tokenize(":^^^") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :"^^^"}], ""}
      # concat_op3
      assert tokenize(":+++") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :+++}], ""}
      assert tokenize(":---") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :---}], ""}
      # ellipsis_op3
      assert tokenize(":...") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :...}], ""}
    end

    test "special handling of :::" do
      # TODO: assert on warning
      assert tokenize(":::") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :"::"}], ""}
    end

    test "two-token operators as atoms" do
      # comp_op2
      assert tokenize(":==") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :==}], ""}
      assert tokenize(":!=") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :!=}], ""}
      assert tokenize(":=~") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :=~}], ""}
      # rel_op2
      assert tokenize(":>=") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :>=}], ""}
      assert tokenize(":<=") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :<=}], ""}
      # and_op
      assert tokenize(":&&") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :&&}], ""}
      # or_op
      assert tokenize(":||") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :||}], ""}
      # arrow_op
      assert tokenize(":|>") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :|>}], ""}
      assert tokenize(":~>") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :~>}], ""}
      assert tokenize(":<~") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :<~}], ""}
      # in_match_op
      assert tokenize(":<-") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :<-}], ""}
      assert tokenize(":\\\\") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :"\\\\"}], ""}
      # concat_op
      assert tokenize(":++") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :++}], ""}
      assert tokenize(":--") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :--}], ""}
      # power_op
      assert tokenize(":**") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :**}], ""}
      # stab_op
      assert tokenize(":->") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :->}], ""}
      # range_op
      assert tokenize(":..") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :..}], ""}
    end

    test "single-token operators as atoms" do
      # at_op
      assert tokenize(":@") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :@}], ""}
      # unary_op
      assert tokenize(":!") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :!}], ""}
      assert tokenize(":^") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :^}], ""}
      # capture_op
      assert tokenize(":&") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :&}], ""}
      # dual_op
      assert tokenize(":+") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :+}], ""}
      assert tokenize(":-") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :-}], ""}
      # mult_op
      assert tokenize(":*") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :*}], ""}
      assert tokenize(":/") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :/}], ""}
      # rel_op
      assert tokenize(":<") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :<}], ""}
      assert tokenize(":>") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :>}], ""}
      # match_op
      assert tokenize(":=") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :=}], ""}
      # pipe_op
      assert tokenize(":|") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :|}], ""}
      # dot
      assert tokenize(":.") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :.}], ""}
    end

    test "followed by other characters" do
      assert tokenize(":~~~;") == {:ok, [{:atom, {{1, 1}, {1, 5}, nil}, :"~~~"}, {:";", {{1, 5}, {1, 6}, 0}}], ""}
      assert tokenize(":::;") == {:ok, [{:atom, {{1, 1}, {1, 4}, nil}, :"::"}, {:";", {{1, 4}, {1, 5}, 0}}], ""}
      assert tokenize(":.;") == {:ok, [{:atom, {{1, 1}, {1, 3}, nil}, :.}, {:";", {{1, 3}, {1, 4}, 0}}], ""}
    end
  end

  describe "stand alone tokens" do
    test "=>" do
      assert tokenize("=>") == {:ok, [{:assoc_op, {{1, 1}, {1, 3}, nil}, :"=>"}], ""}
    end

    test "=> after eol" do
      assert tokenize("\n=>") == {:ok, [{:assoc_op, {{2, 1}, {2, 3}, 1}, :"=>"}], ""}
      assert tokenize("\n\n=>") == {:ok, [{:assoc_op, {{3, 1}, {3, 3}, 2}, :"=>"}], ""}
    end

    # TODO

    # test "=> after ;" do
    #   # assert tokenize(";=>") == {:ok, [{:assoc_op, {2, 1, 1}, :"=>"}], ""}
    #   assert tokenize(";\n=>") == {:ok, [{:assoc_op, {3, 1, 2}, :"=>"}], ""}
    # end

    # test "=> after ," do
    #   # assert tokenize(";=>") == {:ok, [{:assoc_op, {2, 1, 1}, :"=>"}], ""}
    #   assert tokenize(";\n=>") == {:ok, [{:assoc_op, {3, 1, 2}, :"=>"}], ""}
    # end

    test "..//" do
      assert tokenize("..///") == {:ok, [{:identifier, {{1, 1}, {1, 5}, nil}, :..//}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("..// /") == {:ok, [{:identifier, {{1, 1}, {1, 5}, nil}, :..//}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
    end
  end

  describe "operators" do
    test "three token operators" do
      # unary_op3
      assert tokenize("~~~") == {:ok, [{:unary_op, {{1, 1}, {1, 4}, nil}, :"~~~"}], ""}
      # comp_op3
      assert tokenize("===") == {:ok, [{:comp_op, {{1, 1}, {1, 4}, nil}, :===}], ""}
      assert tokenize("!==") == {:ok, [{:comp_op, {{1, 1}, {1, 4}, nil}, :!==}], ""}
      # and_op3
      assert tokenize("&&&") == {:ok, [{:and_op, {{1, 1}, {1, 4}, nil}, :&&&}], ""}
      # or_op3
      assert tokenize("|||") == {:ok, [{:or_op, {{1, 1}, {1, 4}, nil}, :|||}], ""}
      # arrow_op3
      assert tokenize("<<<") == {:ok, [{:arrow_op, {{1, 1}, {1, 4}, nil}, :<<<}], ""}
      assert tokenize(">>>") == {:ok, [{:arrow_op, {{1, 1}, {1, 4}, nil}, :>>>}], ""}
      assert tokenize("~>>") == {:ok, [{:arrow_op, {{1, 1}, {1, 4}, nil}, :~>>}], ""}
      assert tokenize("<<~") == {:ok, [{:arrow_op, {{1, 1}, {1, 4}, nil}, :<<~}], ""}
      assert tokenize("<~>") == {:ok, [{:arrow_op, {{1, 1}, {1, 4}, nil}, :<~>}], ""}
      assert tokenize("<|>") == {:ok, [{:arrow_op, {{1, 1}, {1, 4}, nil}, :"<|>"}], ""}
      # xor_op3
      assert tokenize("^^^") == {:ok, [{:xor_op, {{1, 1}, {1, 4}, nil}, :"^^^"}], ""}
      # concat_op3
      assert tokenize("+++") == {:ok, [{:concat_op, {{1, 1}, {1, 4}, nil}, :+++}], ""}
      assert tokenize("---") == {:ok, [{:concat_op, {{1, 1}, {1, 4}, nil}, :---}], ""}
      # ellipsis_op3
      assert tokenize("...") == {:ok, [{:ellipsis_op, {{1, 1}, {1, 4}, nil}, :...}], ""}
    end

    test "two-token operators" do
      # comp_op2
      assert tokenize("==") == {:ok, [{:comp_op, {{1, 1}, {1, 3}, nil}, :==}], ""}
      assert tokenize("!=") == {:ok, [{:comp_op, {{1, 1}, {1, 3}, nil}, :!=}], ""}
      assert tokenize("=~") == {:ok, [{:comp_op, {{1, 1}, {1, 3}, nil}, :=~}], ""}
      # rel_op2
      assert tokenize(">=") == {:ok, [{:rel_op, {{1, 1}, {1, 3}, nil}, :>=}], ""}
      assert tokenize("<=") == {:ok, [{:rel_op, {{1, 1}, {1, 3}, nil}, :<=}], ""}
      # and_op
      assert tokenize("&&") == {:ok, [{:and_op, {{1, 1}, {1, 3}, nil}, :&&}], ""}
      # or_op
      assert tokenize("||") == {:ok, [{:or_op, {{1, 1}, {1, 3}, nil}, :||}], ""}
      # arrow_op
      assert tokenize("|>") == {:ok, [{:arrow_op, {{1, 1}, {1, 3}, nil}, :|>}], ""}
      assert tokenize("~>") == {:ok, [{:arrow_op, {{1, 1}, {1, 3}, nil}, :~>}], ""}
      assert tokenize("<~") == {:ok, [{:arrow_op, {{1, 1}, {1, 3}, nil}, :<~}], ""}
      # in_match_op
      assert tokenize("<-") == {:ok, [{:in_match_op, {{1, 1}, {1, 3}, nil}, :<-}], ""}
      assert tokenize("\\\\") == {:ok, [{:in_match_op, {{1, 1}, {1, 3}, nil}, :"\\\\"}], ""}
      # concat_op
      assert tokenize("++") == {:ok, [{:concat_op, {{1, 1}, {1, 3}, nil}, :++}], ""}
      assert tokenize("--") == {:ok, [{:concat_op, {{1, 1}, {1, 3}, nil}, :--}], ""}
      # power_op
      assert tokenize("**") == {:ok, [{:power_op, {{1, 1}, {1, 3}, nil}, :**}], ""}
      # stab_op
      assert tokenize("->") == {:ok, [{:stab_op, {{1, 1}, {1, 3}, nil}, :->}], ""}
      # range_op
      assert tokenize("..") == {:ok, [{:range_op, {{1, 1}, {1, 3}, nil}, :..}], ""}
      # type_op
      assert tokenize("::") == {:ok, [{:type_op, {{1, 1}, {1, 3}, nil}, :"::"}], ""}
    end

    test "ternary_op" do
      assert tokenize("//") == {:ok, [{:ternary_op, {{1, 1}, {1, 3}, nil}, :"//"}], ""}
    end

    test "ternary_op after eol" do
      assert tokenize("\n//") == {:ok, [{:ternary_op, {{2, 1}, {2, 3}, 1}, :"//"}], ""}
    end

    test "," do
      assert tokenize(",") == {:ok, [{:",", {{1, 1}, {1, 2}, 0}}], ""}
    end

    test "<<>>" do
      assert tokenize("<<>>") == {:ok, [{:"<<", {{1, 1}, {1, 3}, nil}}, {:">>", {{1, 3}, {1, 5}, nil}}], ""}
    end

    test ">> after eol" do
      # TODO: eol with only position???
      assert tokenize("<<\n>>") == {:ok, [{:"<<", {{1, 1}, {1, 3}, nil}}, {:eol, {1, 3, 1}}, {:">>", {{2, 1}, {2, 3}, 1}}], ""}
    end

    # TODO
    # test "space between % and {" do
    #   assert tokenize("% {") == {:ok, [{:ternary_op, {2, 1, 1}, :"::"}], ""}
    # end

    test "[]" do
      assert tokenize("[]") == {:ok, [{:"[", {{1, 1}, {1, 2}, nil}}, {:"]", {{1, 2}, {1, 3}, nil}}], ""}
    end

    test "] after eol" do
      assert tokenize("[\n]") == {:ok, [{:"[", {{1, 1}, {1, 2}, nil}}, {:eol, {1, 2, 1}}, {:"]", {{2, 1}, {2, 2}, 1}}], ""}
    end

    test "{}" do
      assert tokenize("{}") == {:ok, [{:"{", {{1, 1}, {1, 2}, nil}}, {:"}", {{1, 2}, {1, 3}, nil}}], ""}
    end

    test "} after eol" do
      assert tokenize("{\n}") == {:ok, [{:"{", {{1, 1}, {1, 2}, nil}}, {:eol, {1, 2, 1}}, {:"}", {{2, 1}, {2, 2}, 1}}], ""}
    end

    test "()" do
      assert tokenize("()") == {:ok, [{:"(", {{1, 1}, {1, 2}, nil}}, {:")", {{1, 2}, {1, 3}, nil}}], ""}
    end

    test ") after eol" do
      assert tokenize("(\n)") == {:ok, [{:"(", {{1, 1}, {1, 2}, nil}}, {:eol, {1, 2, 1}}, {:")", {{2, 1}, {2, 2}, 1}}], ""}
    end

    test "single-token operators" do
      # at_op
      assert tokenize("@") == {:ok, [{:at_op, {{1, 1}, {1, 2}, nil}, :@}], ""}
      # unary_op
      assert tokenize("!") == {:ok, [{:unary_op, {{1, 1}, {1, 2}, nil}, :!}], ""}
      assert tokenize("^") == {:ok, [{:unary_op, {{1, 1}, {1, 2}, nil}, :^}], ""}
      # dual_op
      assert tokenize("+") == {:ok, [{:dual_op, {{1, 1}, {1, 2}, nil}, :+}], ""}
      assert tokenize("-") == {:ok, [{:dual_op, {{1, 1}, {1, 2}, nil}, :-}], ""}
      # mult_op
      assert tokenize("*") == {:ok, [{:mult_op, {{1, 1}, {1, 2}, nil}, :*}], ""}
      assert tokenize("/") == {:ok, [{:mult_op, {{1, 1}, {1, 2}, nil}, :/}], ""}
      # rel_op
      assert tokenize("<") == {:ok, [{:rel_op, {{1, 1}, {1, 2}, nil}, :<}], ""}
      assert tokenize(">") == {:ok, [{:rel_op, {{1, 1}, {1, 2}, nil}, :>}], ""}
      # match_op
      assert tokenize("=") == {:ok, [{:match_op, {{1, 1}, {1, 2}, nil}, :=}], ""}
      # pipe_op
      assert tokenize("|") == {:ok, [{:pipe_op, {{1, 1}, {1, 2}, nil}, :|}], ""}
    end

    test "capture_int" do
      assert tokenize("&1") == {:ok, [{:capture_int, {{1, 1}, {1, 2}, nil}, :&}, {:int, {{1, 2}, {1, 3}, 1}, ~c"1"}], ""}
      assert tokenize("& 1") == {:ok, [{:capture_op, {{1, 1}, {1, 2}, nil}, :&}, {:int, {{1, 3}, {1, 4}, 1}, ~c"1"}], ""}
    end

    test "capture_op" do
      assert tokenize("&+/1") == {:ok, [{:capture_op, {{1, 1}, {1, 2}, nil}, :&}, {:identifier, {{1, 2}, {1, 3}, nil}, :+}, {:mult_op, {{1, 3}, {1, 4}, nil}, :/}, {:int, {{1, 4}, {1, 5}, 1}, ~c"1"}], ""}
      assert tokenize("& +/1") == {:ok, [{:capture_op, {{1, 1}, {1, 2}, nil}, :&}, {:identifier, {{1, 3}, {1, 4}, nil}, :+}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}, {:int, {{1, 5}, {1, 6}, 1}, ~c"1"}], ""}
    end

    test "capture_op /" do
      assert tokenize("&//") == {:ok, [{:capture_op, {{1, 1}, {1, 2}, nil}, :&}, {:ternary_op, {{1, 2}, {1, 4}, nil}, :"//"}], ""}
      assert tokenize("& //") == {:ok, [{:capture_op, {{1, 1}, {1, 2}, nil}, :&}, {:ternary_op, {{1, 3}, {1, 5}, nil}, :"//"}], ""}
      # TODO: invalid range
      assert tokenize("&/ /") == {:ok, [{:capture_op, {{1, 1}, {1, 2}, nil}, :&}, {:identifier, {{1, 2}, {1, 3}, nil}, :/}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      assert tokenize("&/+") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :&}, {:mult_op, {{1, 2}, {1, 3}, nil}, :/}, {:dual_op, {{1, 3}, {1, 4}, nil}, :+}], ""}
      assert tokenize("& /+") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :&}, {:mult_op, {{1, 3}, {1, 4}, nil}, :/}, {:dual_op, {{1, 4}, {1, 5}, nil}, :+}], ""}
      assert tokenize("&/ +") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :&}, {:mult_op, {{1, 2}, {1, 3}, nil}, :/}, {:dual_op, {{1, 4}, {1, 5}, nil}, :+}], ""}
    end

    # TODO: is there a test?
      # # dot
      # assert tokenize(":.") == {:ok, [{:atom, {1, 1, nil}, :.}], ""}

    # TODO: invalid range
    test "unary operators followed by /" do
      # unary_op3
      assert tokenize("~~~  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :"~~~"}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # ellipsis_op3
      assert tokenize("...  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :"..."}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # at_op
      assert tokenize("@  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :@}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      # unary_op
      assert tokenize("!  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :!}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      assert tokenize("^  \t/") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :^}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # dual_op
      assert tokenize("+  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :+}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      assert tokenize("-  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :-}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
    end

    # TODO: invalid range
    test "operators followed by /" do
      # comp_op3
      assert tokenize("===  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :===}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize("!==  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :!==}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # and_op3
      assert tokenize("&&&  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :&&&}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # or_op3
      assert tokenize("|||  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :|||}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # xor_op3
      assert tokenize("^^^  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :^^^}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # concat_op3
      assert tokenize("+++  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :+++}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize("---  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :---}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # arrow_op3
      assert tokenize("<<<  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :<<<}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize(">>>  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :>>>}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize("~>>  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :~>>}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize("<<~  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :<<~}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize("<~>  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :<~>}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      assert tokenize("<|>  /") == {:ok, [{:identifier, {{1, 1}, {1, 4}, nil}, :<|>}, {:mult_op, {{1, 6}, {1, 7}, nil}, :/}], ""}
      # power_op
      assert tokenize("**  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :**}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # range_op
      assert tokenize("..  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :..}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # concat_op
      assert tokenize("++  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :++}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("--  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :--}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # arrow_op
      assert tokenize("|>  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :|>}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("~>  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :~>}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("<~  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :<~}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # comp_op2
      assert tokenize("==  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :==}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("!=  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :!=}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("=~  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :=~}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # rel_op2
      assert tokenize(">=  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :>=}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("<=  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :<=}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # and_op
      assert tokenize("&&  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :&&}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # or_op
      assert tokenize("||  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :||}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # in_match_op
      assert tokenize("<-  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :<-}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      assert tokenize("\\\\  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :"\\\\"},  {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # type_op
      assert tokenize("::  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :"::"},  {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # stab_op
      assert tokenize("->  /") == {:ok, [{:identifier, {{1, 1}, {1, 3}, nil}, :->}, {:mult_op, {{1, 5}, {1, 6}, nil}, :/}], ""}
      # rel_op
      assert tokenize("<  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :<}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      assert tokenize(">  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :>}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      # mult_op
      assert tokenize("*  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :*}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      assert tokenize("/  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :/}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      # match_op
      assert tokenize("=  /") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :=}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
      # pipe_op
      assert tokenize("| \t/") == {:ok, [{:identifier, {{1, 1}, {1, 2}, nil}, :|}, {:mult_op, {{1, 4}, {1, 5}, nil}, :/}], ""}
    end

    test "unary operators at start of line after newline" do
      # Unary minus after newline should have nil EOL meta
      assert tokenize("\n-1") == {:ok, [
        {:eol, {1, 1, 1}},
        {:dual_op, {{2, 1}, {2, 2}, nil}, :-},
        {:int, {{2, 2}, {2, 3}, 1}, ~c"1"}
      ], ""}

      # Unary plus after newline should have nil EOL meta
      assert tokenize("\n+1") == {:ok, [
        {:eol, {1, 1, 1}},
        {:dual_op, {{2, 1}, {2, 2}, nil}, :+},
        {:int, {{2, 2}, {2, 3}, 1}, ~c"1"}
      ], ""}
    end

    test "unary operators with indentation after newline" do
      # Indented unary minus
      assert tokenize("\n  -1") == {:ok, [
        {:eol, {1, 1, 1}},
        {:dual_op, {{2, 3}, {2, 4}, nil}, :-},
        {:int, {{2, 4}, {2, 5}, 1}, ~c"1"}
      ], ""}

      # Indented unary plus
      assert tokenize("\n\t+1") == {:ok, [
        {:eol, {1, 1, 1}},
        {:dual_op, {{2, 2}, {2, 3}, nil}, :+},
        {:int, {{2, 3}, {2, 4}, 1}, ~c"1"}
      ], ""}
    end

    test "at_op after newline has nil EOL meta" do
      assert tokenize("\n@x") == {:ok, [
        {:eol, {1, 1, 1}},
        {:at_op, {{2, 1}, {2, 2}, nil}, :@},
        {:identifier, {{2, 2}, {2, 3}, ~c"x"}, :x}
      ], ""}
    end
  end

  describe "spaces" do
    test "horizontal spaces are properly handled" do
      # Spaces should be skipped during tokenization
      assert tokenize("0x123    :+") ==
               {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}, {:atom, {{1, 10}, {1, 12}, nil}, :+}], ""}

      # Multiple consecutive spaces
      assert tokenize("0x123 \t  0b101") ==
               {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}, {:int, {{1, 10}, {1, 15}, 5}, ~c"0b101"}], ""}
    end
  end

  describe "end of line handling" do
    test "semicolons" do
      assert tokenize(";") == {:ok, [{:";", {{1, 1}, {1, 2}, 0}}], ""}
    end

    test "tokens after semicolons" do
      assert tokenize(";0x123") == {:ok, [{:";", {{1, 1}, {1, 2}, 0}}, {:int, {{1, 2}, {1, 7}, 291}, ~c"0x123"}], ""}
    end

    test "semicolons after tokens" do
      assert tokenize("0x123;") == {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}, {:";", {{1, 6}, {1, 7}, 0}}], ""}
    end

    test "consecutive semicolons" do
      # TODO: this is a syntax error
      # assert tokenize(";;") == {:ok, [{";", {1, 1, 0}}, {";", {1, 2, 0}}], ""}
    end

    # test "commas" do
    #   assert tokenize(",") == {:ok, [{",", {1, 1, 0}}], ""}
    # end

    # test "tokens after commas" do
    #   assert tokenize(",0x123") == {:ok, [{",", {1, 1, 0}}, {:int, {1, 2, 291}, "0x123"}], ""}
    # end

    # test "commas after tokens" do
    #   assert tokenize("0x123,") == {:ok, [{:int, {1, 1, 291}, "0x123"}], ","}
    # end

    # test "consecutive commas" do
    #   assert tokenize(",,") == {:ok, [{",", {1, 1, 0}}, {",", {1, 2, 0}}], ""}
    # end

    test "newlines" do
      assert tokenize("\n") == {:ok, [{:eol, {1, 1, 1}}], ""}
    end

    test "consecutive newlines" do
      assert tokenize("\n\n") == {:ok, [{:eol, {1, 1, 2}}], ""}
    end

    test "carriage return + newline" do
      assert tokenize("\r\n") == {:ok, [{:eol, {1, 1, 1}}], ""}
    end

    test "consecutive carriage return + newline" do
      assert tokenize("\r\n\r\n") == {:ok, [{:eol, {1, 1, 2}}], ""}
    end

    test "newlines with horizontal spaces" do
      assert tokenize("\n  0") == {:ok, [{:eol, {1, 1, 1}}, {:int, {{2, 3}, {2, 4}, 0}, ~c"0"}], ""}
    end

    test "escaped newlines are handled" do
      # Escaped newlines should continue to next line without creating eol token
      assert tokenize("\\\n0x123") == {:ok, [{:int, {{2, 1}, {2, 6}, 291}, ~c"0x123"}], ""}
      assert tokenize("\\\r\n0x123") == {:ok, [{:int, {{2, 1}, {2, 6}, 291}, ~c"0x123"}], ""}
      # TODO: this is a syntax error
      # assert tokenize("\\\n") == {:ok, [], ""}
      # assert tokenize("\\\r\n") == {:ok, [], ""}
      # assert tokenize("\\") == {:ok, [], ""}
    end

    test "consecutive escaped newlines" do
      assert tokenize("\\\n\\\n0x123") == {:ok, [{:int, {{3, 1}, {3, 6}, 291}, ~c"0x123"}], ""}
    end

    test "newline after escaped newline" do
      assert tokenize("\\\n\n") == {:ok, [{:eol, {2, 1, 1}}], ""}
    end

    test "horizontal space after escaped newline" do
      assert tokenize("\\\n 0x123") == {:ok, [{:int, {{2, 2}, {2, 7}, 291}, ~c"0x123"}], ""}
    end

    test "tokens before newlines" do
      assert tokenize("0x123\n") == {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}, {:eol, {1, 6, 1}}], ""}
    end

    test "tokens after newlines" do
      assert tokenize("\n0x123") == {:ok, [{:eol, {1, 1, 1}}, {:int, {{2, 1}, {2, 6}, 291}, ~c"0x123"}], ""}
    end

    test "tokens before consecutive newlines" do
      assert tokenize("0x123\n\n") == {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}, {:eol, {1, 6, 2}}], ""}
    end

    test "tokens after consecutive newlines" do
      assert tokenize("\n\n0x123") == {:ok, [{:eol, {1, 1, 2}}, {:int, {{3, 1}, {3, 6}, 291}, ~c"0x123"}], ""}
    end
  end

  describe "bin strings" do
    test "empty bin strings" do
      assert tokenize("\"\"") == {:ok, [{:bin_string, {{1, 1}, {1, 3}, nil}, [""]}], ""}
    end

    test "simple bin strings" do
      assert tokenize("\"foo\"") == {:ok, [{:bin_string, {{1, 1}, {1, 6}, nil}, ["foo"]}], ""}
    end

    test "unicode bin strings" do
      assert tokenize("\"ą\"") == {:ok, [{:bin_string, {{1, 1}, {1, 4}, nil}, ["ą"]}], ""}
    end

    test "with LF newlines" do
      assert tokenize("\"foo\nbar\"") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foo\nbar"]}], ""}
    end

    test "with CRLF newlines" do
      assert tokenize("\"foo\r\nbar\"") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foo\r\nbar"]}], ""}
    end

    test "with escaped LF newlines" do
      assert tokenize("\"foo\\\nbar\"") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foobar"]}], ""}
    end

    test "with escaped CRLF newlines" do
      assert tokenize("\"foo\\\r\nbar\"") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foobar"]}], ""}
    end

    test "with LF escape" do
      assert tokenize("\"foo\\nbar\"") == {:ok, [{:bin_string, {{1, 1}, {1, 11}, nil}, ["foo\nbar"]}], ""}
    end

    test "with CRLF escape" do
      assert tokenize("\"foo\\r\\nbar\"") ==
               {:ok, [{:bin_string, {{1, 1}, {1, 13}, nil}, ["foo\r\nbar"]}], ""}
    end

    test "with terminator escape" do
      assert tokenize("\"foo\\\"bar\"") == {:ok, [{:bin_string, {{1, 1}, {1, 11}, nil}, ["foo\"bar"]}], ""}
    end

    test "tokens after bin strings same line" do
      assert tokenize("\"foo\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {1, 6}, nil}, ["foo"]}, {:int, {{1, 7}, {1, 12}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after bin strings next line" do
      assert tokenize("\"foo\"\n0x123") == {
        :ok,
        [
          {:bin_string, {{1, 1}, {1, 6}, nil}, ["foo"]},
          {:eol, {1, 6, 1}},
          {:int, {{2, 1}, {2, 6}, 291}, ~c"0x123"}
        ],
        ""
      }
    end

    test "tokens after unicode bin strings" do
      assert tokenize("\"ą\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {1, 4}, nil}, ["ą"]}, {:int, {{1, 5}, {1, 10}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after string with LF newlines" do
      assert tokenize("\"foo\nbar\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foo\nbar"]}, {:int, {{2, 6}, {2, 11}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after string with CRLF newlines" do
      assert tokenize("\"foo\r\nbar\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foo\r\nbar"]}, {:int, {{2, 6}, {2, 11}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after string with escaped LF newlines" do
      assert tokenize("\"foo\\\nbar\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foobar"]}, {:int, {{2, 6}, {2, 11}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after string with escaped CRLF newlines" do
      assert tokenize("\"foo\\\r\nbar\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {2, 5}, nil}, ["foobar"]}, {:int, {{2, 6}, {2, 11}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after string with LF escape" do
      assert tokenize("\"foo\\nbar\" 0x123") == {:ok, [{:bin_string, {{1, 1}, {1, 11}, nil}, ["foo\nbar"]}, {:int, {{1, 12}, {1, 17}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after string with CRLF escape" do
      assert tokenize("\"foo\\r\\nbar\" 0x123") ==
               {:ok, [{:bin_string, {{1, 1}, {1, 13}, nil}, ["foo\r\nbar"]}, {:int, {{1, 14}, {1, 19}, 291}, ~c"0x123"}], ""}
    end

    test "with interpolation in the middle" do
      assert tokenize("\"foo \#{0x123} baz\"") == {:ok, [{:bin_string, {{1, 1}, {1, 19}, nil}, ["foo ", {{1, 6, nil}, {1, 13, nil}, [{:int, {{1, 8}, {1, 13}, 291}, ~c"0x123"}]}, " baz"]}], ""}
    end

    test "with interpolation in the beginning" do
      assert tokenize("\"\#{0x123} baz\"") == {
        :ok,
        [
          {
            :bin_string,
            {{1, 1}, {1, 15}, nil},
            [
              {{1, 2, nil}, {1, 9, nil}, [{:int, {{1, 4}, {1, 9}, 291}, ~c"0x123"}]},
              " baz"
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation in the end" do
      assert tokenize("\"foo \#{0x123}\"") == {
        :ok,
        [
          {
            :bin_string,
            {{1, 1}, {1, 15}, nil},
            [
              "foo ",
              {{1, 6, nil}, {1, 13, nil}, [{:int, {{1, 8}, {1, 13}, 291}, ~c"0x123"}]}
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation next to interpolation" do
      assert tokenize("\"a \#{0x123}\#{0x124} baz\"") == {
        :ok,
        [
          {
            :bin_string,
            {{1, 1}, {1, 25}, nil},
            [
              "a ",
              {{1, 4, nil}, {1, 11, nil}, [{:int, {{1, 6}, {1, 11}, 291}, ~c"0x123"}]},
              {{1, 12, nil}, {1, 19, nil}, [{:int, {{1, 14}, {1, 19}, 292}, ~c"0x124"}]},
              " baz"
            ]
          }
        ],
        ""
      }
    end

    test "with nested interpolation" do
      assert tokenize("\"foo \#{\"inner \#{0x123} \"} baz\"") == {:ok, [{:bin_string, {{1, 1}, {1, 31}, nil}, ["foo ", {{1, 6, nil}, {1, 25, nil}, [{:bin_string, {{1, 8}, {1, 25}, nil}, ["inner ", {{1, 15, nil}, {1, 22, nil}, [{:int, {{1, 17}, {1, 22}, 291}, ~c"0x123"}]}, " "]}]}, " baz"]}], ""}
    end

    test "with escaped interpolation" do
      assert tokenize("\"foo \\\#{0x123} baz\"") == {:ok, [{:bin_string, {{1, 1}, {1, 20}, nil}, ["foo \#{0x123} baz"]}], ""}
    end
  end

  describe "charlist strings" do
    test "empty charlist strings" do
      assert tokenize("''") == {:ok, [{:list_string, {{1, 1}, {1, 3}, nil}, [""]}], ""}
    end

    test "simple charlist strings" do
      assert tokenize("'foo'") == {:ok, [{:list_string, {{1, 1}, {1, 6}, nil}, ["foo"]}], ""}
    end

    test "unicode charlist strings" do
      assert tokenize("'ą'") == {:ok, [{:list_string, {{1, 1}, {1, 4}, nil}, ["ą"]}], ""}
    end

    test "with LF newlines" do
      assert tokenize("'foo\nbar'") == {:ok, [{:list_string, {{1, 1}, {2, 5}, nil}, ["foo\nbar"]}], ""}
    end

    test "with CRLF newlines" do
      assert tokenize("'foo\r\nbar'") == {:ok, [{:list_string, {{1, 1}, {2, 5}, nil}, ["foo\r\nbar"]}], ""}
    end

    test "with escaped LF newlines" do
      assert tokenize("'foo\\\nbar'") == {:ok, [{:list_string, {{1, 1}, {2, 5}, nil}, ["foobar"]}], ""}
    end

    test "with escaped CRLF newlines" do
      assert tokenize("'foo\\\r\nbar'") == {:ok, [{:list_string, {{1, 1}, {2, 5}, nil}, ["foobar"]}], ""}
    end

    test "with LF escape" do
      assert tokenize("'foo\\nbar'") == {:ok, [{:list_string, {{1, 1}, {1, 11}, nil}, ["foo\nbar"]}], ""}
    end

    test "with CRLF escape" do
      assert tokenize("'foo\\r\\nbar'") ==
               {:ok, [{:list_string, {{1, 1}, {1, 13}, nil}, ["foo\r\nbar"]}], ""}
    end

    test "with terminator escape" do
      assert tokenize("'foo\\'bar'") == {:ok, [{:list_string, {{1, 1}, {1, 11}, nil}, ["foo'bar"]}], ""}
    end

    test "with interpolation" do
      assert tokenize("'foo \#{0x123} baz'") == {:ok, [{:list_string, {{1, 1}, {1, 19}, nil}, ["foo ", {{1, 6, nil}, {1, 13, nil}, [{:int, {{1, 8}, {1, 13}, 291}, ~c"0x123"}]}, " baz"]}], ""}
    end

    test "with escaped interpolation" do
      assert tokenize("'foo \\\#{0x123} baz'") == {:ok, [{:list_string, {{1, 1}, {1, 20}, nil}, ["foo \#{0x123} baz"]}], ""}
    end
  end

  describe "bin heredocs" do
    test "empty heredocs" do
      assert tokenize("\"\"\"\n\"\"\"") == {:ok, [{:bin_heredoc, {{1, 1}, {2, 4}, nil}, 0, [""]}], ""}
    end

    test "simple heredocs" do
      assert tokenize("\"\"\"\nfoo\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\n"]}], ""}
    end

    test "simple heredocs CRLF" do
      assert tokenize("\"\"\"\r\nfoo\r\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\r\n"]}], ""}
    end

    test "simple with indentation" do
      assert tokenize("\"\"\"\n  foo\n  \"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 6}, nil}, 2, ["foo\n"]}], ""}
    end

    test "simple with tab indentation" do
      assert tokenize("\"\"\"\n\tfoo\n\t\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 5}, nil}, 1, ["foo\n"]}], ""}
    end

    test "simple with indentation CRLF" do
      assert tokenize("\"\"\"\r\n  foo\r\n  \"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 6}, nil}, 2, ["foo\r\n"]}], ""}
    end

    test "escaped final newline" do
      assert tokenize("\"\"\"\nfoo\\\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo"]}], ""}
    end

    test "escaped final newline CRLF" do
      assert tokenize("\"\"\"\r\nfoo\\\r\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo"]}], ""}
    end

    test "with newline" do
      assert tokenize("\"\"\"\nfoo\nbar\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foo\nbar\n"]}], ""}
    end

    test "with newline CRLF" do
      assert tokenize("\"\"\"\r\nfoo\r\nbar\r\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foo\r\nbar\r\n"]}], ""}
    end

    test "with escaped newline" do
      assert tokenize("\"\"\"\nfoo\\\nbar\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foobar\n"]}], ""}
    end

    test "with escaped newline CRLF" do
      assert tokenize("\"\"\"\r\nfoo\\\r\nbar\r\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foobar\r\n"]}], ""}
    end

    test "with LF escape" do
      assert tokenize("\"\"\"\nfoo\\nbar\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\nbar\n"]}], ""}
    end

    test "with CRLF escape" do
      assert tokenize("\"\"\"\r\nfoo\\r\\nbar\r\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\r\nbar\r\n"]}], ""}
    end

    test "tokens after heredoc next line" do
      assert tokenize("\"\"\"\nfoo\n\"\"\"\n0x123") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\n"]}, {:eol, {3, 4, 1}}, {:int, {{4, 1}, {4, 6}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after heredoc same line" do
      assert tokenize("\"\"\"\nfoo\n\"\"\" 0x123") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\n"]}, {:int, {{3, 5}, {3, 10}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after multiline heredoc" do
      assert tokenize("\"\"\"\nfoo\nbar\n\"\"\"\n0x123") == {:ok, [{:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foo\nbar\n"]}, {:eol, {4, 4, 1}}, {:int, {{5, 1}, {5, 6}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after heredoc with escaped LF" do
      assert tokenize("\"\"\"\nfoo\\\nbar\n\"\"\"\n0x123") == {
        :ok,
        [
          {:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foobar\n"]},
          {:eol, {4, 4, 1}},
          {:int, {{5, 1}, {5, 6}, 291}, ~c"0x123"}
        ],
        ""
      }
    end

    test "tokens after heredoc with escaped CRLF" do
      assert tokenize("\"\"\"\r\nfoo\\\r\nbar\r\n\"\"\"\n0x123") == {
        :ok,
        [
          {:bin_heredoc, {{1, 1}, {4, 4}, nil}, 0, ["foobar\r\n"]},
          {:eol, {4, 4, 1}},
          {:int, {{5, 1}, {5, 6}, 291}, ~c"0x123"}
        ],
        ""
      }
    end

    test "tokens after heredoc with LF escape" do
      assert tokenize("\"\"\"\nfoo\\nbar\n\"\"\"\n0x123") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\nbar\n"]}, {:eol, {3, 4, 1}}, {:int, {{4, 1}, {4, 6}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after heredoc with CRLF escape" do
      assert tokenize("\"\"\"\r\nfoo\\r\\nbar\r\n\"\"\"\n0x123") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\r\nbar\r\n"]}, {:eol, {3, 4, 1}}, {:int, {{4, 1}, {4, 6}, 291}, ~c"0x123"}], ""}
    end

    test "tokens after escaped final newline" do
      assert tokenize("\"\"\"\nfoo\\\n\"\"\"\n0x123") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo"]}, {:eol, {3, 4, 1}}, {:int, {{4, 1}, {4, 6}, 291}, ~c"0x123"}], ""}
    end

    test "with interpolation in the middle of the line" do
      assert tokenize("\"\"\"\nfoo \#{0x123} baz\n\"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {3, 4}, nil},
            0,
            [
              "foo ",
              {{2, 5, nil}, {2, 12, nil}, [{:int, {{2, 7}, {2, 12}, 291}, ~c"0x123"}]},
              " baz\n"
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation at the beginning of the line" do
      assert tokenize("\"\"\"\n\#{0x123} baz\n\"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {3, 4}, nil},
            0,
            [
              "",
              {{2, 1, nil}, {2, 8, nil}, [{:int, {{2, 3}, {2, 8}, 291}, ~c"0x123"}]},
              " baz\n"
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation at the end of the line" do
      assert tokenize("\"\"\"\nfoo \#{0x123}\n\"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {3, 4}, nil},
            0,
            [
              "foo ",
              {{2, 5, nil}, {2, 12, nil}, [{:int, {{2, 7}, {2, 12}, 291}, ~c"0x123"}]},
              "\n"
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation at the end of the line with newline escaped" do
      assert tokenize("\"\"\"\nfoo \#{0x123}\\\n\"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {3, 4}, nil},
            0,
            [
              "foo ",
              {{2, 5, nil}, {2, 12, nil}, [{:int, {{2, 7}, {2, 12}, 291}, ~c"0x123"}]},
              ""
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation next to interpolation" do
      assert tokenize("\"\"\"\nfoo \#{0x123}\#{0x124} baz\n\"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {3, 4}, nil},
            0,
            [
              "foo ",
              {{2, 5, nil}, {2, 12, nil}, [{:int, {{2, 7}, {2, 12}, 291}, ~c"0x123"}]},
              {{2, 13, nil}, {2, 20, nil}, [{:int, {{2, 15}, {2, 20}, 292}, ~c"0x124"}]},
              " baz\n"
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation next to interpolation separated by newline" do
      assert tokenize("\"\"\"\nfoo \#{0x123}\n\#{0x124} baz\n\"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {4, 4}, nil},
            0,
            [
              "foo ",
              {{2, 5, nil}, {2, 12, nil}, [{:int, {{2, 7}, {2, 12}, 291}, ~c"0x123"}]},
              "\n",
              {{3, 1, nil}, {3, 8, nil}, [{:int, {{3, 3}, {3, 8}, 292}, ~c"0x124"}]},
              " baz\n"
            ]
          }
        ],
        ""
      }
    end

    test "with interpolation next to interpolation separated by newline with indentation" do
      assert tokenize("\"\"\"\n foo \#{0x123}\n \#{0x124} baz\n \"\"\"") == {
        :ok,
        [
          {
            :bin_heredoc,
            {{1, 1}, {4, 5}, nil},
            1,
            [
              "foo ",
              {{2, 6, nil}, {2, 13, nil}, [{:int, {{2, 8}, {2, 13}, 291}, ~c"0x123"}]},
              "\n",
              {{3, 2, nil}, {3, 9, nil}, [{:int, {{3, 4}, {3, 9}, 292}, ~c"0x124"}]},
              " baz\n"
            ]
          }
        ],
        ""
      }
    end

    test "with escaped interpolation" do
      assert tokenize("\"\"\"\nfoo \\\#{0x123} baz\n\"\"\"") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo \#{0x123} baz\n"]}], ""}
    end

    test "with escaped terminator" do
      assert tokenize("\"\"\"\nfoo\\\"\"\"bar\n\"\"\"") == {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\"\"\"bar\n"]}], ""}
    end

    test "line with less indentation" do
      assert tokenize("\"\"\"\n \n  \n  \"\"\"") == {:ok, [{:bin_heredoc, {{1, 1}, {4, 6}, nil}, 2, ["\n\n"]}], ""}
    end

    test "line with more indentation" do
      assert tokenize("\"\"\"\n   \n  \n  \"\"\"") == {:ok, [{:bin_heredoc, {{1, 1}, {4, 6}, nil}, 2, [" \n\n"]}], ""}
    end

    test "horizontal space before first newline" do
      assert tokenize("\"\"\" \t\nfoo\n\"\"\"") ==
               {:ok, [{:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\n"]}], ""}
    end
  end

  describe "charlist heredocs" do
    test "empty heredocs" do
      assert tokenize("'''\n'''") == {:ok, [{:list_heredoc, {{1, 1}, {2, 4}, nil}, 0, [""]}], ""}
    end

    test "simple heredocs" do
      assert tokenize("'''\nfoo\n'''") == {:ok, [{:list_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\n"]}], ""}
    end

    test "simple heredocs CRLF" do
      assert tokenize("'''\r\nfoo\r\n'''") ==
               {:ok, [{:list_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo\r\n"]}], ""}
    end

    test "simple with indentation" do
      assert tokenize("'''\n  foo\n  '''") ==
               {:ok, [{:list_heredoc, {{1, 1}, {3, 6}, nil}, 2, ["foo\n"]}], ""}
    end

    test "simple with indentation CRLF" do
      assert tokenize("'''\r\n  foo\r\n  '''") ==
               {:ok, [{:list_heredoc, {{1, 1}, {3, 6}, nil}, 2, ["foo\r\n"]}], ""}
    end

    test "with escaped terminator" do
      assert tokenize("'''\nfoo\\'''bar\n'''") == {:ok, [{:list_heredoc, {{1, 1}, {3, 4}, nil}, 0, ["foo'''bar\n"]}], ""}
    end
  end

  describe "char" do
    test "simple char" do
      assert tokenize("?a") == {:ok, [{:char, {{1, 1}, {1, 3}, ~c"?a"}, ?a}], ""}
    end

    test "LF" do
      # TODO: range is wrong
      assert tokenize("?\n") == {:ok, [{:char, {{1, 1}, {1, 3}, ~c"?\n"}, ?\n}], ""}
    end

    test "CR" do
      assert tokenize("?\r") == {:ok, [{:char, {{1, 1}, {1, 3}, ~c"?\r"}, ?\r}], ""}
    end

    test "NULL" do
      assert tokenize("?\0") == {:ok, [{:char, {{1, 1}, {1, 3}, [63, 0]}, ?\0}], ""}
    end

    test "CR LF" do
      assert tokenize("?\r\n") == {:ok, [{:char, {{1, 1}, {1, 3}, ~c"?\r"}, ?\r}, {:eol, {1, 3, 1}}], ""}
    end

    test "escape" do
      assert tokenize("?\\0") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\0"}, ?\0}], ""}
      assert tokenize("?\\a") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\a"}, ?\a}], ""}
      assert tokenize("?\\\\") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\\\"}, ?\\}], ""}
    end

    test "unknown escape" do
      assert tokenize("?\\z") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\z"}, ?z}], ""}
    end

    test "unknown escape non letter" do
      assert tokenize("?\\1") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\1"}, ?1}], ""}
    end

    test "escape LF" do
      # TODO: range is invalid
      assert tokenize("?\\\n") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\\n"}, ?\n}], ""}
    end

    test "escape CR LF" do
      # TODO: range is invalid?
      assert tokenize("?\\\r\n") == {:ok, [{:char, {{1, 1}, {1, 4}, ~c"?\\\r"}, ?\r}, {:eol, {1, 4, 1}}], ""}
    end
  end

  describe "comments" do
    test "empty comment" do
      assert tokenize("#") == {:ok, [], ""}
    end

    test "comment after newline" do
      assert tokenize("\n#foo") == {:ok, [{:eol, {1, 1, 0}}], ""}
    end

    test "comment after comma" do
      assert tokenize(", #foo") == {:ok, [{:",", {{1, 1}, {1, 2}, 0}}], ""}
    end

    test "comment after semicolon" do
      assert tokenize("; #foo") == {:ok, [{:";", {{1, 1}, {1, 2}, 0}}], ""}
    end

    test "comment with spaces" do
      assert tokenize("# foo") == {:ok, [], ""}
    end

    test "comment with LF" do
      assert tokenize("#foo\n") == {:ok, [{:eol, {1, 1, 1}}], ""}
    end

    test "comment with CRLF" do
      assert tokenize("#foo\r\n") == {:ok, [{:eol, {1, 1, 1}}], ""}
    end

    test "code before comment" do
      assert tokenize("0x123 # foo") == {:ok, [{:int, {{1, 1}, {1, 6}, 291}, ~c"0x123"}], ""}
    end

    test "code after comment" do
      assert tokenize("# foo\n0x123") ==
               {:ok, [{:eol, {1, 1, 1}}, {:int, {{2, 1}, {2, 6}, 291}, ~c"0x123"}], ""}
    end

    test "multiline comment" do
      source = """
      # SPDX-License-Identifier: Apache-2.0
      # SPDX-FileCopyrightText: 2021 The Elixir Team
      """
      assert {:ok, _, _} = tokenize(source)
    end

    test "identifier after multiline comment" do
      source = """
      # SPDX-License-Identifier: Apache-2.0
      # SPDX-FileCopyrightText: 2021 The Elixir Team
      defmodule
      """
      assert {:ok, _, _} = tokenize(source)
    end

    test "identifier after multiline comment and newline" do
      source = """
      # SPDX-License-Identifier: Apache-2.0
      # SPDX-FileCopyrightText: 2021 The Elixir Team
      # SPDX-FileCopyrightText: 2012 Plataformatec

      defmodule
      """
      assert {:ok, _, _} = tokenize(source)
    end

    # test "comment with bidi" do
    #   assert tokenize("#\u202Afoo") == {:ok, [], ""}
    # end
  end

  describe "non operator atoms" do
    test "quoted" do
      assert tokenize(":\"a\"") == {:ok, [{:atom_quoted, {{1, 1}, {1, 5}, 34}, :a}], ""}
      assert tokenize(":'a'") == {:ok, [{:atom_quoted, {{1, 1}, {1, 5}, 39}, :a}], ""}
    end

    test "quoted newline escape" do
      assert tokenize(":\"a\\n\" 1") == {:ok, [{:atom_quoted, {{1, 1}, {1, 7}, 34}, :"a\n"}, {:int, {{1, 8}, {1, 9}, 1}, ~c"1"}], ""}
      assert tokenize(":'a\\n' 1") == {:ok, [{:atom_quoted, {{1, 1}, {1, 7}, 39}, :"a\n"}, {:int, {{1, 8}, {1, 9}, 1}, ~c"1"}], ""}
    end

    test "quoted newline" do
      assert tokenize(":\"a\n\" 1") == {:ok, [{:atom_quoted, {{1, 1}, {2, 2}, 34}, :"a\n"}, {:int, {{2, 3}, {2, 4}, 1}, ~c"1"}], ""}
      assert tokenize(":'a\n' 1") == {:ok, [{:atom_quoted, {{1, 1}, {2, 2}, 39}, :"a\n"}, {:int, {{2, 3}, {2, 4}, 1}, ~c"1"}], ""}
    end

    test "quoted escaped newline" do
      assert tokenize(":\"a\\\n\" 1") == {:ok, [{:atom_quoted, {{1, 1}, {2, 2}, 34}, :a}, {:int, {{2, 3}, {2, 4}, 1}, ~c"1"}], ""}
      assert tokenize(":'a\\\n' 1") == {:ok, [{:atom_quoted, {{1, 1}, {2, 2}, 39}, :a}, {:int, {{2, 3}, {2, 4}, 1}, ~c"1"}], ""}
    end

    test "quoted unicode" do
      assert tokenize(":\"ą\"") == {:ok, [{:atom_quoted, {{1, 1}, {1, 5}, 34}, :ą}], ""}
      assert tokenize(":'ą'") == {:ok, [{:atom_quoted, {{1, 1}, {1, 5}, 39}, :ą}], ""}
    end

    test "quoted with interpolation at the end" do
      assert tokenize(":\"a \#{1}\"") == {:ok, [{:atom_unsafe, {{1, 1}, {1, 10}, 34}, ["a ", {{1, 5, nil}, {1, 8, nil}, [{:int, {{1, 7}, {1, 8}, 1}, ~c"1"}]}]}], ""}
      assert tokenize(":'a \#{1}'") == {:ok, [{:atom_unsafe, {{1, 1}, {1, 10}, 39}, ["a ", {{1, 5, nil}, {1, 8, nil}, [{:int, {{1, 7}, {1, 8}, 1}, ~c"1"}]}]}], ""}
    end

    test "quoted with interpolation at the beginning" do
      assert tokenize(":\"\#{1}a\"") == {:ok, [{:atom_unsafe, {{1, 1}, {1, 9}, 34}, [{{1, 3, nil}, {1, 6, nil}, [{:int, {{1, 5}, {1, 6}, 1}, ~c"1"}]}, "a"]}], ""}
      assert tokenize(":'\#{1}a'") == {:ok, [{:atom_unsafe, {{1, 1}, {1, 9}, 39}, [{{1, 3, nil}, {1, 6, nil}, [{:int, {{1, 5}, {1, 6}, 1}, ~c"1"}]}, "a"]}], ""}
    end

    test "quoted with interpolation in the middle" do
      assert tokenize(":\"a \#{1} b\"") == {:ok, [{:atom_unsafe, {{1, 1}, {1, 12}, 34}, ["a ", {{1, 5, nil}, {1, 8, nil}, [{:int, {{1, 7}, {1, 8}, 1}, ~c"1"}]}, " b"]}], ""}
      assert tokenize(":'a \#{1} b'") == {:ok, [{:atom_unsafe, {{1, 1}, {1, 12}, 39}, ["a ", {{1, 5, nil}, {1, 8, nil}, [{:int, {{1, 7}, {1, 8}, 1}, ~c"1"}]}, " b"]}], ""}
    end

    test "quoted with escaped interpolation in the middle" do
      assert tokenize(":\"a \\\#{1} b\" 1") == {:ok, [{:atom_quoted, {{1, 1}, {1, 13}, 34}, :"a \#{1} b"}, {:int, {{1, 14}, {1, 15}, 1}, ~c"1"}], ""}
      assert tokenize(":'a \\\#{1} b' 1") == {:ok, [{:atom_quoted, {{1, 1}, {1, 13}, 39}, :"a \#{1} b"}, {:int, {{1, 14}, {1, 15}, 1}, ~c"1"}], ""}
    end

    test "simple" do
      assert tokenize(":foo") == {:ok, [{:atom, {{1, 1}, {1, 5}, ~c"foo"}, :foo}], ""}
    end

    test "with underscore" do
      assert tokenize(":_foo") == {:ok, [{:atom, {{1, 1}, {1, 6}, ~c"_foo"}, :_foo}], ""}
      assert tokenize(":foo_bar") == {:ok, [{:atom, {{1, 1}, {1, 9}, ~c"foo_bar"}, :foo_bar}], ""}
      assert tokenize(":_foo_bar_") == {:ok, [{:atom, {{1, 1}, {1, 11}, ~c"_foo_bar_"}, :_foo_bar_}], ""}
    end

    test "with numbers" do
      assert tokenize(":foo123") == {:ok, [{:atom, {{1, 1}, {1, 8}, ~c"foo123"}, :foo123}], ""}
      assert tokenize(":foo_123") == {:ok, [{:atom, {{1, 1}, {1, 9}, ~c"foo_123"}, :foo_123}], ""}
    end

    test "with @ character" do
      # @ is allowed in atom names after the first character
      assert tokenize(":foo@bar") == {:ok, [{:atom, {{1, 1}, {1, 9}, ~c"foo@bar"}, :foo@bar}], ""}
      assert tokenize(":foo@123") == {:ok, [{:atom, {{1, 1}, {1, 9}, ~c"foo@123"}, :foo@123}], ""}
      assert tokenize(":foo@") == {:ok, [{:atom, {{1, 1}, {1, 6}, ~c"foo@"}, :foo@}], ""}
    end

    test "ending with ? or !" do
      assert tokenize(":foo?") == {:ok, [{:atom, {{1, 1}, {1, 6}, ~c"foo?"}, :foo?}], ""}
      assert tokenize(":foo!") == {:ok, [{:atom, {{1, 1}, {1, 6}, ~c"foo!"}, :foo!}], ""}
      assert tokenize(":_foo?") == {:ok, [{:atom, {{1, 1}, {1, 7}, ~c"_foo?"}, :_foo?}], ""}
      assert tokenize(":_foo!") == {:ok, [{:atom, {{1, 1}, {1, 7}, ~c"_foo!"}, :_foo!}], ""}
    end

    test "unicode letters - latin extended" do
      assert tokenize(":café") == {:ok, [{:atom, {{1, 1}, {1, 6}, [99, 97, 102, 233]}, :café}], ""}
      assert tokenize(":niño") == {:ok, [{:atom, {{1, 1}, {1, 6}, [110, 105, 241, 111]}, :niño}], ""}
      assert tokenize(":ação") == {:ok, [{:atom, {{1, 1}, {1, 6}, [97, 231, 227, 111]}, :ação}], ""}
    end

    test "unicode letters - greek" do
      assert tokenize(":αβγ") == {:ok, [{:atom, {{1, 1}, {1, 5}, [945, 946, 947]}, :αβγ}], ""}
      assert tokenize(":Ωμέγα") == {:ok, [{:atom, {{1, 1}, {1, 7}, [937, 956, 941, 947, 945]}, :Ωμέγα}], ""}
    end

    test "unicode letters - cyrillic" do
      assert tokenize(":привет") == {:ok, [{:atom, {{1, 1}, {1, 8}, [1087, 1088, 1080, 1074, 1077, 1090]}, :привет}], ""}
      assert tokenize(":_Москва") == {:ok, [{:atom, {{1, 1}, {1, 9}, [95, 1052, 1086, 1089, 1082, 1074, 1072]}, :_Москва}], ""}
    end

    test "unicode letters - japanese" do
      assert tokenize(":こんにちは") == {:ok, [{:atom, {{1, 1}, {1, 7}, [12371, 12435, 12395, 12385, 12399]}, :こんにちは}], ""}
      assert tokenize(":カタカナ") == {:ok, [{:atom, {{1, 1}, {1, 6}, [12459, 12479, 12459, 12490]}, :カタカナ}], ""}
    end

    test "unicode letters - chinese" do
      assert tokenize(":你好") == {:ok, [{:atom, {{1, 1}, {1, 4}, [20320, 22909]}, :你好}], ""}
      assert tokenize(":世界") == {:ok, [{:atom, {{1, 1}, {1, 4}, [19990, 30028]}, :世界}], ""}
    end

    test "unicode letters - arabic" do
      assert tokenize(":مرحبا") == {:ok, [{:atom, {{1, 1}, {1, 7}, [1605, 1585, 1581, 1576, 1575]}, :مرحبا}], ""}
      assert tokenize(":_سلام") == {:ok, [{:atom, {{1, 1}, {1, 7}, [95, 1587, 1604, 1575, 1605]}, :_سلام}], ""}
    end

    test "unicode letters - hebrew" do
      assert tokenize(":שלום") == {:ok, [{:atom, {{1, 1}, {1, 6}, [1513, 1500, 1493, 1501]}, :שלום}], ""}
      assert tokenize(":_עברית") == {:ok, [{:atom, {{1, 1}, {1, 8}, [95, 1506, 1489, 1512, 1497, 1514]}, :_עברית}], ""}
    end

    test "unicode with mixed scripts separated by underscore" do
      assert tokenize(":hello_世界") == {:ok, [{:atom, {{1, 1}, {1, 10}, [104, 101, 108, 108, 111, 95, 19990, 30028]}, :hello_世界}], ""}
      assert tokenize(":test_тест") == {:ok, [{:atom, {{1, 1}, {1, 11}, [116, 101, 115, 116, 95, 1090, 1077, 1089, 1090]}, :test_тест}], ""}
    end

    test "unicode with numbers and special characters" do
      assert tokenize(":café123") == {:ok, [{:atom, {{1, 1}, {1, 9}, [99, 97, 102, 233, 49, 50, 51]}, :café123}], ""}
      assert tokenize(":test_123_δ") == {:ok, [{:atom, {{1, 1}, {1, 12}, [116, 101, 115, 116, 95, 49, 50, 51, 95, 948]}, :test_123_δ}], ""}
      assert tokenize(":привет_world") == {:ok, [{:atom, {{1, 1}, {1, 14}, [1087, 1088, 1080, 1074, 1077, 1090, 95, 119, 111, 114, 108, 100]}, :привет_world}], ""}
    end

    test "unicode with ending punctuation" do
      assert tokenize(":café?") == {:ok, [{:atom, {{1, 1}, {1, 7}, [99, 97, 102, 233, 63]}, :café?}], ""}
      assert tokenize(":αβγ!") == {:ok, [{:atom, {{1, 1}, {1, 6}, [945, 946, 947, 33]}, :αβγ!}], ""}
      assert tokenize(":_世界?") == {:ok, [{:atom, {{1, 1}, {1, 6}, [95, 19990, 30028, 63]}, :_世界?}], ""}
    end

    test "special case - micro sign normalized to mu" do
      # MICRO SIGN (µ) should be normalized to Greek lowercase mu (μ)
      assert tokenize(":µs") == {:ok, [{:atom, {{1, 1}, {1, 4}, [956, 115]}, :μs}], ""}
      assert tokenize(":micro_µ_second") == {:ok, [{:atom, {{1, 1}, {1, 16}, [109, 105, 99, 114, 111, 95, 956, 95, 115, 101, 99, 111, 110, 100]}, :micro_μ_second}], ""}
    end

    test "ISO8601 example from docs" do
      assert tokenize(":ISO8601") == {:ok, [{:atom, {{1, 1}, {1, 9}, ~c"ISO8601"}, :ISO8601}], ""}
    end
  end

  describe "identifier" do
    test "simple identifier" do
      assert tokenize("foo") == {:ok, [{:identifier, {{1, 1}, {1, 4}, ~c"foo"}, :foo}], ""}
    end

    test "unicode identifier - latin extended" do
      assert tokenize("café") == {:ok, [{:identifier, {{1, 1}, {1, 5}, [99, 97, 102, 233]}, :café}], ""}
    end

    test "unicode identifier - simple greek" do
      assert tokenize("αβγ") == {:ok, [{:identifier, {{1, 1}, {1, 4}, [945, 946, 947]}, :αβγ}], ""}
    end

    test "unicode identifier - mixed unicode and ascii" do
      assert tokenize("testé") == {:ok, [{:identifier, {{1, 1}, {1, 6}, [116, 101, 115, 116, 233]}, :testé}], ""}
    end

    test "identifier with underscore" do
      assert tokenize("foo_bar") == {:ok, [{:identifier, {{1, 1}, {1, 8}, ~c"foo_bar"}, :foo_bar}], ""}
    end

    test "identifier starting with underscore" do
      assert tokenize("_foo") == {:ok, [{:identifier, {{1, 1}, {1, 5}, ~c"_foo"}, :_foo}], ""}
    end

    test "identifier ending with question mark" do
      assert tokenize("foo?") == {:ok, [{:identifier, {{1, 1}, {1, 5}, ~c"foo?"}, :foo?}], ""}
    end

    test "identifier ending with exclamation mark" do
      assert tokenize("foo!") == {:ok, [{:identifier, {{1, 1}, {1, 5}, ~c"foo!"}, :foo!}], ""}
    end

    test "identifier with numbers" do
      assert tokenize("foo123") == {:ok, [{:identifier, {{1, 1}, {1, 7}, ~c"foo123"}, :foo123}], ""}
    end
  end

  describe "alias" do
    test "simple alias" do
      assert tokenize("Foo") == {:ok, [{:alias, {{1, 1}, {1, 4}, ~c"Foo"}, :Foo}], ""}
    end

    test "alias with underscore" do
      assert tokenize("FooBar") == {:ok, [{:alias, {{1, 1}, {1, 7}, ~c"FooBar"}, :FooBar}], ""}
    end

    test "alias with underscore in middle" do
      assert tokenize("Foo_Bar") == {:ok, [{:alias, {{1, 1}, {1, 8}, ~c"Foo_Bar"}, :Foo_Bar}], ""}
    end

    test "alias with underscore at end" do
      assert tokenize("Foo_") == {:ok, [{:alias, {{1, 1}, {1, 5}, ~c"Foo_"}, :Foo_}], ""}
    end

    test "alias with numbers" do
      assert tokenize("Foo123") == {:ok, [{:alias, {{1, 1}, {1, 7}, ~c"Foo123"}, :Foo123}], ""}
    end

    test "nested alias" do
      assert tokenize("Foo.Bar") == {:ok, [{:alias, {{1, 1}, {1, 4}, ~c"Foo"}, :Foo}, {:., {{1, 4}, {1, 5}, nil}}, {:alias, {{1, 5}, {1, 8}, ~c"Bar"}, :Bar}], ""}
    end

    test "multiple nested aliases" do
      assert tokenize("Foo.Bar.Baz") == {:ok, [{:alias, {{1, 1}, {1, 4}, ~c"Foo"}, :Foo}, {:., {{1, 4}, {1, 5}, nil}}, {:alias, {{1, 5}, {1, 8}, ~c"Bar"}, :Bar}, {:., {{1, 8}, {1, 9}, nil}}, {:alias, {{1, 9}, {1, 12}, ~c"Baz"}, :Baz}], ""}
    end
  end

  describe "kw_identifier" do
    test "simple kw_identifier" do
      assert tokenize("foo: bar") == {:ok, [{:kw_identifier, {{1, 1}, {1, 5}, ~c"foo"}, :foo}, {:identifier, {{1, 6}, {1, 9}, ~c"bar"}, :bar}], ""}
    end

    test "kw_identifier with underscore" do
      assert tokenize("foo_bar: baz") == {:ok, [{:kw_identifier, {{1, 1}, {1, 9}, ~c"foo_bar"}, :foo_bar}, {:identifier, {{1, 10}, {1, 13}, ~c"baz"}, :baz}], ""}
    end

    test "kw_identifier starting with underscore" do
      assert tokenize("_foo: bar") == {:ok, [{:kw_identifier, {{1, 1}, {1, 6}, ~c"_foo"}, :_foo}, {:identifier, {{1, 7}, {1, 10}, ~c"bar"}, :bar}], ""}
    end

    test "kw_identifier ending with question mark" do
      assert tokenize("foo?: bar") == {:ok, [{:kw_identifier, {{1, 1}, {1, 6}, ~c"foo?"}, :foo?}, {:identifier, {{1, 7}, {1, 10}, ~c"bar"}, :bar}], ""}
    end

    test "kw_identifier ending with exclamation mark" do
      assert tokenize("foo!: bar") == {:ok, [{:kw_identifier, {{1, 1}, {1, 6}, ~c"foo!"}, :foo!}, {:identifier, {{1, 7}, {1, 10}, ~c"bar"}, :bar}], ""}
    end

    test "kw_identifier with numbers" do
      assert tokenize("foo123: bar") == {:ok, [{:kw_identifier, {{1, 1}, {1, 8}, ~c"foo123"}, :foo123}, {:identifier, {{1, 9}, {1, 12}, ~c"bar"}, :bar}], ""}
    end

    test "kw_identifier in list" do
      assert tokenize("[foo: bar]") == {:ok, [{:"[", {{1, 1}, {1, 2}, nil}}, {:kw_identifier, {{1, 2}, {1, 6}, ~c"foo"}, :foo}, {:identifier, {{1, 7}, {1, 10}, ~c"bar"}, :bar}, {:"]", {{1, 10}, {1, 11}, nil}}], ""}
    end

    test "multiple kw_identifiers" do
      assert tokenize("foo: bar, baz: qux") == {:ok, [
        {:kw_identifier, {{1, 1}, {1, 5}, ~c"foo"}, :foo},
        {:identifier, {{1, 6}, {1, 9}, ~c"bar"}, :bar},
        {:",", {{1, 9}, {1, 10}, 0}},
        {:kw_identifier, {{1, 11}, {1, 15}, ~c"baz"}, :baz},
        {:identifier, {{1, 16}, {1, 19}, ~c"qux"}, :qux}
      ], ""}
    end

    test "kw_identifier with single quoted string value" do
      assert tokenize("foo: 'bar'") == {:ok, [{:kw_identifier, {{1, 1}, {1, 5}, ~c"foo"}, :foo}, {:list_string, {{1, 6}, {1, 11}, nil}, ["bar"]}], ""}
    end

    test "kw_identifier with double quoted string value" do
      assert tokenize("foo: \"bar\"") == {:ok, [{:kw_identifier, {{1, 1}, {1, 5}, ~c"foo"}, :foo}, {:bin_string, {{1, 6}, {1, 11}, nil}, ["bar"]}], ""}
    end

    test "kw_identifier with atom value" do
      assert tokenize("foo: :bar") == {:ok, [{:kw_identifier, {{1, 1}, {1, 5}, ~c"foo"}, :foo}, {:atom, {{1, 6}, {1, 10}, ~c"bar"}, :bar}], ""}
    end

    test "kw_identifier with integer value" do
      assert tokenize("foo: 123") == {:ok, [{:kw_identifier, {{1, 1}, {1, 5}, ~c"foo"}, :foo}, {:int, {{1, 6}, {1, 9}, 123}, ~c"123"}], ""}
    end


    test "identifier without colon should remain identifier" do
      assert tokenize("foo bar") == {:ok, [{:identifier, {{1, 1}, {1, 4}, ~c"foo"}, :foo}, {:identifier, {{1, 5}, {1, 8}, ~c"bar"}, :bar}], ""}
    end

    test "double quoted kw_identifier" do
      assert tokenize("\"foo\": 1") == {:ok, [{:kw_identifier, {{1, 1}, {1, 7}, 34}, :foo}, {:int, {{1, 8}, {1, 9}, 1}, ~c"1"}], ""}
    end

    test "single quoted kw_identifier" do
      assert tokenize("'bar': 2") == {:ok, [{:kw_identifier, {{1, 1}, {1, 7}, 39}, :bar}, {:int, {{1, 8}, {1, 9}, 2}, ~c"2"}], ""}
    end

    test "multiple quoted kw_identifiers" do
      assert tokenize("\"foo\": 1, 'bar': 2") == {:ok, [
        {:kw_identifier, {{1, 1}, {1, 7}, 34}, :foo},
        {:int, {{1, 8}, {1, 9}, 1}, ~c"1"},
        {:",", {{1, 9}, {1, 10}, 0}},
        {:kw_identifier, {{1, 11}, {1, 17}, 39}, :bar},
        {:int, {{1, 18}, {1, 19}, 2}, ~c"2"}
      ], ""}
    end

    test "quoted kw_identifier with newline" do
      assert tokenize("\"hello\nworld\": :ok") == {:ok, [{:kw_identifier, {{1, 1}, {2, 8}, 34}, :"hello\nworld"}, {:atom, {{2, 9}, {2, 12}, ~c"ok"}, :ok}], ""}
    end

    test "quoted kw_identifier with escaped newline" do
      assert tokenize("\"hello\\\nworld\": :ok") == {:ok, [{:kw_identifier, {{1, 1}, {2, 8}, 34}, :helloworld}, {:atom, {{2, 9}, {2, 12}, ~c"ok"}, :ok}], ""}
    end

    test "quoted kw_identifier with newline escape" do
      assert tokenize("\"hello\\nworld\": :ok") == {:ok, [{:kw_identifier, {{1, 1}, {1, 16}, 34}, :"hello\nworld"}, {:atom, {{1, 17}, {1, 20}, ~c"ok"}, :ok}], ""}
    end

    test "quoted kw_identifier with interpolation in the middle" do
      assert tokenize("\"hello \#{1} world\": :ok") == {:ok, [
        {
          :kw_identifier_unsafe,
          {{1, 1}, {1, 20}, 34},
          ["hello ", {{1, 8, nil}, {1, 11, nil}, [{:int, {{1, 10}, {1, 11}, 1}, ~c"1"}]}, " world"]
        },
        {:atom, {{1, 21}, {1, 24}, ~c"ok"}, :ok}
      ], ""}
    end

    test "quoted kw_identifier with interpolation at the end" do
      assert tokenize("\"hello \#{1}\": :ok") == {:ok, [
        {:kw_identifier_unsafe, {{1, 1}, {1, 14}, 34}, ["hello ", {{1, 8, nil}, {1, 11, nil}, [{:int, {{1, 10}, {1, 11}, 1}, ~c"1"}]}]},
        {:atom, {{1, 15}, {1, 18}, ~c"ok"}, :ok}
      ], ""}
    end

    test "quoted kw_identifier with interpolation at the beginning" do
      assert tokenize("\"\#{1}hello\": :ok") == {:ok, [
        {:kw_identifier_unsafe, {{1, 1}, {1, 13}, 34}, [{{1, 2, nil}, {1, 5, nil}, [{:int, {{1, 4}, {1, 5}, 1}, ~c"1"}]}, "hello"]},
        {:atom, {{1, 14}, {1, 17}, ~c"ok"}, :ok}
      ], ""}
    end

    test "quoted kw_identifier with escaped interpolation in the middle" do
      assert tokenize("\"hello \\\#{1} world\": :ok") == {:ok, [{:kw_identifier, {{1, 1}, {1, 21}, 34}, :"hello \#{1} world"}, {:atom, {{1, 22}, {1, 25}, ~c"ok"}, :ok}], ""}
    end

    test "quoted kw_identifier with numbers in name" do
      assert tokenize("\"key123\": value") == {:ok, [{:kw_identifier, {{1, 1}, {1, 10}, 34}, :key123}, {:identifier, {{1, 11}, {1, 16}, ~c"value"}, :value}], ""}
    end
  end

  describe "dot" do
    test "standalone dot" do
      assert tokenize(".") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}], ""}
    end

    test "dot followed by space" do
      assert tokenize(". ") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}], ""}
    end

    test "dot three-token operator" do
      # unary_op3
      assert tokenize(".~~~") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"~~~"}, :"~~~"}], ""}
      # comp_op3
      assert tokenize(".===") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"==="}, :===}], ""}
      assert tokenize(".!==") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"!=="}, :!==}], ""}
      # and_op3
      assert tokenize(".&&&") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"&&&"}, :&&&}], ""}
      # or_op3
      assert tokenize(".|||") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"|||"}, :|||}], ""}
      # arrow_op3
      assert tokenize(".<<<") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"<<<"}, :<<<}], ""}
      assert tokenize(".>>>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c">>>"}, :>>>}], ""}
      assert tokenize(".~>>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"~>>"}, :~>>}], ""}
      assert tokenize(".<<~") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"<<~"}, :<<~}], ""}
      assert tokenize(".<~>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"<~>"}, :<~>}], ""}
      assert tokenize(".<|>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"<|>"}, :<|>}], ""}
      # xor_op3
      assert tokenize(".^^^") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"^^^"}, :^^^}], ""}
      # concat_op3
      assert tokenize(".+++") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"+++"}, :+++}], ""}
      assert tokenize(".---") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 5}, ~c"---"}, :---}], ""}
    end

    test "dot two-token operators" do
      # comp_op2
      assert tokenize(".==") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"=="}, :==}], ""}
      assert tokenize(".!=") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"!="}, :!=}], ""}
      assert tokenize(".=~") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"=~"}, :=~}], ""}
      # rel_op2
      assert tokenize(".>=") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c">="}, :>=}], ""}
      assert tokenize(".<=") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"<="}, :<=}], ""}
      # and_op
      assert tokenize(".&&") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"&&"}, :&&}], ""}
      # or_op
      assert tokenize(".||") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"||"}, :||}], ""}
      # arrow_op
      assert tokenize(".|>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"|>"}, :|>}], ""}
      assert tokenize(".~>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"~>"}, :~>}], ""}
      assert tokenize(".<~") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"<~"}, :<~}], ""}
      # in_match_op
      assert tokenize(".<-") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"<-"}, :<-}], ""}
      assert tokenize(".\\\\") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"\\\\"}, :"\\\\"}], ""}
      # concat_op
      assert tokenize(".++") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"++"}, :++}], ""}
      assert tokenize(".--") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"--"}, :--}], ""}
      # power_op
      assert tokenize(".**") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"**"}, :**}], ""}
      # type_op
      assert tokenize(".::") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 4}, ~c"::"}, :"::"}], ""}
    end

    test "dot single-token operators" do
      # at_op
      assert tokenize(".@") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"@"}, :@}], ""}
      # unary_op
      assert tokenize(".!") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"!"}, :!}], ""}
      assert tokenize(".^") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"^"}, :^}], ""}
      # capture_op
      assert tokenize(".&") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"&"}, :&}], ""}
      # dual_op
      assert tokenize(".+") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"+"}, :+}], ""}
      assert tokenize(".-") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"-"}, :-}], ""}
      # mult_op
      assert tokenize(".*") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"*"}, :*}], ""}
      assert tokenize("./") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"/"}, :/}], ""}
      # rel_op
      assert tokenize(".<") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"<"}, :<}], ""}
      assert tokenize(".>") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c">"}, :>}], ""}
      # match_op
      assert tokenize(".=") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"="}, :=}], ""}
      # pipe_op
      assert tokenize(".|") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 3}, ~c"|"}, :|}], ""}
    end

    test "dot paren" do
      assert tokenize(".(1)") == {:ok, [{:dot_call_op, {{1, 1}, {1, 2}, nil}, :.}, {:"(", {{1, 2}, {1, 3}, nil}}, {:int, {{1, 3}, {1, 4}, 1}, ~c"1"}, {:")", {{1, 4}, {1, 5}, nil}}], ""}
    end

    test "dot quote double" do
      assert tokenize(".\"foo\"") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 7}, 34}, :foo}], ""}
    end

    test "dot quote single" do
      assert tokenize(".'foo'") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 7}, 39}, :foo}], ""}
    end

    test "dot quote newline" do
      # TODO: range is invalid
      assert tokenize(".\"foo\nbar\" 1") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {2, 5}, 34}, :"foo\nbar"}, {:int, {{2, 6}, {2, 7}, 1}, ~c"1"}], ""}
    end

    test "dot quote escaped newline" do
      # TODO: range is invalid on identifier
      assert tokenize(".\"foo\\\nbar\" 1") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 1}, {2, 5}, 34}, :foobar}, {:int, {{2, 6}, {2, 7}, 1}, ~c"1"}], ""}
    end

    test "dot quote newline escape" do
      assert tokenize(".\"foo\\nbar\" 1") == {:ok, [{:., {{1, 1}, {1, 2}, nil}}, {:identifier, {{1, 2}, {1, 12}, 34}, :"foo\nbar"}, {:int, {{1, 13}, {1, 14}, 1}, ~c"1"}], ""}
    end
  end

  describe "reserved words" do
    test "true" do
      assert tokenize("true") == {:ok, [{:true, {{1, 1}, {1, 5}, nil}}], ""}
    end

    test "false" do
      assert tokenize("false") == {:ok, [{:false, {{1, 1}, {1, 6}, nil}}], ""}
    end

    test "nil" do
      assert tokenize("nil") == {:ok, [{:nil, {{1, 1}, {1, 4}, nil}}], ""}
    end

    test "when" do
      assert tokenize("when") == {:ok, [{:when_op, {{1, 1}, {1, 5}, nil}, :when}], ""}
    end

    test "and" do
      assert tokenize("and") == {:ok, [{:and_op, {{1, 1}, {1, 4}, nil}, :and}], ""}
    end

    test "or" do
      assert tokenize("or") == {:ok, [{:or_op, {{1, 1}, {1, 3}, nil}, :or}], ""}
    end

    test "not" do
      assert tokenize("not") == {:ok, [{:unary_op, {{1, 1}, {1, 4}, nil}, :not}], ""}
    end

    test "not in" do
      assert tokenize("not in") == {:ok, [{:in_op, {{1, 1}, {1, 7}, nil}, :"not in"}], ""}
      assert tokenize("not  in") == {:ok, [{:in_op, {{1, 1}, {1, 8}, nil}, :"not in"}], ""}
      # TODO: report to elixir
      # assert tokenize("not\nin") == {:ok, [{:in_op, {{1, 1}, {1, 8}, nil}, :"not in"}], ""}
    end

    test "in" do
      assert tokenize("in") == {:ok, [{:in_op, {{1, 1}, {1, 3}, nil}, :in}], ""}
    end

    test "catch" do
      assert tokenize("catch") == {:ok, [{:block_identifier, {{1, 1}, {1, 6}, nil}, :catch}], ""}
    end

    test "rescue" do
      assert tokenize("rescue") == {:ok, [{:block_identifier, {{1, 1}, {1, 7}, nil}, :rescue}], ""}
    end

    test "after" do
      assert tokenize("after") == {:ok, [{:block_identifier, {{1, 1}, {1, 6}, nil}, :after}], ""}
    end

    test "else" do
      assert tokenize("else") == {:ok, [{:block_identifier, {{1, 1}, {1, 5}, nil}, :else}], ""}
    end
  end

  describe "sigil" do
    test "incomplete" do
      assert tokenize("~x") == {:ok, [], ""}
    end

    test "empty" do
      assert tokenize("~x//") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 5}, nil},
          :sigil_x,
          [""],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "simple" do
      assert tokenize("~x/asd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "/"
        }
      ], ""}

      assert tokenize("~x<asd>") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "<"
        }
      ], ""}

      assert tokenize("~x\"asd\"") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "\""
        }
      ], ""}

      assert tokenize("~x'asd'") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "'"
        }
      ], ""}

      assert tokenize("~x[asd]") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "["
        }
      ], ""}

      assert tokenize("~x(asd)") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "("
        }
      ], ""}

      assert tokenize("~x{asd}") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "{"
        }
      ], ""}

      assert tokenize("~x|asd|") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 8}, nil},
          :sigil_x,
          ["asd"],
          [],
          nil,
          "|"
        }
      ], ""}
    end

    test "heredoc" do
      assert tokenize("~x\"\"\"\nasd\n\"\"\"") == {:ok, [
        {
          :sigil,
          {{1, 1}, {3, 4}, nil},
          :sigil_x,
          ["asd\n"],
          [],
          0,
          "\"\"\""
        }
      ], ""}

      assert tokenize("~x'''\nasd\n'''") == {:ok, [
        {
          :sigil,
          {{1, 1}, {3, 4}, nil},
          :sigil_x,
          ["asd\n"],
          [],
          0,
          "'''"
        }
      ], ""}
    end

    test "heredoc with indent" do
      assert tokenize("~x\"\"\"\n  asd\n  \"\"\"") == {:ok, [
        {
          :sigil,
          {{1, 1}, {3, 6}, nil},
          :sigil_x,
          ["asd\n"],
          [],
          2,
          "\"\"\""
        }
      ], ""}
    end

    test "with modifier" do
      assert tokenize("~x/asd/foo") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 11}, nil},
          :sigil_x,
          ["asd"],
          ~c"foo",
          nil,
          "/"
        }
      ], ""}
    end

    test "capital letters" do
      assert tokenize("~FOO1/asd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 11}, nil},
          :sigil_FOO1,
          ["asd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with escaped terminator" do
      assert tokenize("~x/a\\/sd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 10}, nil},
          :sigil_x,
          ["a/sd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with escaped terminator uppercase" do
      assert tokenize("~X/a\\/sd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 10}, nil},
          :sigil_X,
          ["a/sd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with LF newline" do
      assert tokenize("~x/a\nsd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {2, 4}, nil},
          :sigil_x,
          ["a\nsd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with CR LF newline" do
      assert tokenize("~x/a\r\nsd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {2, 4}, nil},
          :sigil_x,
          ["a\r\nsd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    # TODO: is this a bug?
    test "with escaped LF newline" do
      assert tokenize("~x/a\\\nsd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {2, 4}, nil},
          :sigil_x,
          ["a\\\nsd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    # TODO: is this a bug?
    test "with escaped CR LF newline" do
      assert tokenize("~x/a\\\r\nsd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {2, 4}, nil},
          :sigil_x,
          ["a\\\r\nsd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with LF newline escape" do
      assert tokenize("~x/a\\nsd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 10}, nil},
          :sigil_x,
          ["a\\nsd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with CR LF newline escape" do
      assert tokenize("~x/a\\r\\nsd/") == {:ok, [
        {
          :sigil,
          {{1, 1}, {1, 12}, nil},
          :sigil_x,
          ["a\\r\\nsd"],
          [],
          nil,
          "/"
        }
      ], ""}
    end

    test "with interpolation lowercase" do
      assert tokenize("~x/a\#{123}sd/") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {1, 14}, nil},
            :sigil_x,
            [
              "a",
              {{1, 5, nil}, {1, 10, nil}, [{:int, {{1, 7}, {1, 10}, 123}, ~c"123"}]},
              "sd"
            ],
            [],
            nil,
            "/"
          }
        ],
        ""
      }
    end

    test "with interpolation uppercase" do
      assert tokenize("~X/a\#{123}sd/") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {1, 14}, nil},
            :sigil_X,
            ["a\#{123}sd"],
            [],
            nil,
            "/"
          }
        ],
        ""
      }
    end

    test "with escaped interpolation lowercase" do
      assert tokenize("~x/a\\\#{123}sd/") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {1, 15}, nil},
            :sigil_x,
            ["a\\\#{123}sd"],
            [],
            nil,
            "/"
          }
        ],
        ""
      }
    end

    test "with escaped interpolation uppercase" do
      assert tokenize("~X/a\\\#{123}sd/") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {1, 15}, nil},
            :sigil_X,
            ["a\\\#{123}sd"],
            [],
            nil,
            "/"
          }
        ],
        ""
      }
    end

    test "with interpolation lowercase heredoc" do
      assert tokenize("~x'''\na\#{123}sd\n'''") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {3, 4}, nil},
            :sigil_x,
            [
              "a",
              {
                {2, 2, nil},
                {2, 7, nil},
                [{:int, {{2, 4}, {2, 7}, 123}, ~c"123"}]
              },
              "sd\n"
            ],
            [],
            0,
            "'''"
          }
        ],
        ""
      }
    end

    test "with interpolation uppercase heredoc" do
      assert tokenize("~X'''\na\#{123}sd\n'''") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {3, 4}, nil},
            :sigil_X,
            ["a\#{123}sd\n"],
            [],
            0,
            "'''"
          }
        ],
        ""
      }
    end

    test "with escaped interpolation lowercase heredoc" do
      assert tokenize("~x'''\na\\\#{123}sd\n'''") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {3, 4}, nil},
            :sigil_x,
            ["a\\\#{123}sd\n"],
            [],
            0,
            "'''"
          }
        ],
        ""
      }
    end

    test "with escaped interpolation uppercase heredoc" do
      assert tokenize("~X'''\na\\\#{123}sd\n'''") == {
        :ok,
        [
          {
            :sigil,
            {{1, 1}, {3, 4}, nil},
            :sigil_X,
            ["a\\\#{123}sd\n"],
            [],
            0,
            "'''"
          }
        ],
        ""
      }
    end
  end

  describe "integration" do
    test "module" do
      assert tokenize("defmodule Foo do\nend") == {:ok, [{:identifier, {{1, 1}, {1, 10}, ~c"defmodule"}, :defmodule},
      {:alias, {{1, 11}, {1, 14}, ~c"Foo"}, :Foo},
      # TODO: no range on do
      {:do, {1, 15, nil}},
      {:eol, {1, 17, 1}},
      # TODO: no range on end
      {:end, {{2, 1}, {2, 4}, nil}}], ""}
    end

    test "try" do
      assert tokenize("try do\n:ok\nend") == {:ok, [{:do_identifier, {{1, 1}, {1, 4}, ~c"try"}, :try},
      {:do, {{1, 5}, {1, 7}, nil}},
      {:eol, {1, 7, 1}},
      {:atom, {{2, 1}, {2, 4}, ~c"ok"}, :ok},
      {:eol, {2, 4, 1}},
      {:end, {{3, 1}, {3, 4}, nil}}], ""}
    end

    test "try with rescue" do
      assert tokenize("try do\n:ok\nrescue\n:error\nafter\n:ok\nelse\n:ok\nend") == {:ok, [
        {:do_identifier, {{1, 1}, {1, 4}, ~c"try"}, :try},
              {:do, {1, 5, nil}},
              {:eol, {1, 7, 1}},
              {:atom, {{2, 1}, {2, 4}, ~c"ok"}, :ok},
              {:eol, {2, 4, 1}},
              {:block_identifier, {{3, 1}, {3, 7}, nil}, :rescue},
              {:eol, {3, 7, 1}},
              {:atom, {{4, 1}, {4, 7}, ~c"error"}, :error},
              {:eol, {4, 7, 1}},
              {:block_identifier, {{5, 1}, {5, 6}, nil}, :after},
              {:eol, {5, 6, 1}},
              {:atom, {{6, 1}, {6, 4}, ~c"ok"}, :ok},
              {:eol, {6, 4, 1}},
              {:block_identifier, {{7, 1}, {7, 5}, nil}, :else},
              {:eol, {7, 5, 1}},
              {:atom, {8, 1, ~c"ok"}, :ok},
        {:eol, {8, 4, 1}},
        {:end, {{9, 1}, {9, 4}, nil}}], ""}
    end

    test "fn" do
      assert tokenize("fn ->\n:ok\nend") == {:ok, [
        # TODO: no range on fn
        {:fn, {{1, 1}, {1, 3}, nil}},
              {:stab_op, {{1, 4}, {1, 6}, nil}, :->},
              {:eol, {1, 6, 1}},
              {:atom, {{2, 1}, {2, 4}, ~c"ok"}, :ok},
              {:eol, {2, 4, 1}},
              {:end, {{3, 1}, {3, 4}, nil}}], ""}
    end

    for module <- [
      Atom,
      Tuple,
      List,
      Map,
      Keyword,
      Bitwise,
      String,
      Integer,
      Float,
      ] do

      @module module
      test "elixir src #{@module}" do
        source = @module.module_info()[:compile][:source] |> File.read!
        # lines = String.split(source, "\n")
        assert {:ok, _, _} = tokenize(source)
      end
    end

    test "elixir src" do
      files = Enum.module_info()[:compile][:source] |> Path.join("../../..") |> Path.expand() |> Path.join("**/*.ex*") |> Path.wildcard
      for file <- files do
        source = file |> File.read!
        # lines = String.split(source, "\n")
        assert {:ok, _, _} = tokenize(source)
      end
    end
  end

  # Ported from elixir/lib/elixir/test/erlang/tokenizer_test.erl
  describe "erlang tokenizer compatibility tests" do
    test "type" do
      assert tokenize("1 :: 3") == {:ok, [
        {:int, {{1, 1}, {1, 2}, 1}, ~c"1"},
        # TODO: range is invalid
        {:type_op, {{1, 3}, {1, 5}, nil}, :"::"},
        {:int, {{1, 6}, {1, 7}, 3}, ~c"3"}
      ], ""}

      assert tokenize("true::3") == {:ok, [
        {:true, {1, 1, nil}},
        {:type_op, {1, 5, nil}, :"::"},
        {:int, {1, 7, 3}, ~c"3"}
      ], ""}

      {:ok, tokens, ""} = tokenize("name.::(3)")
      assert match?([
        {:identifier, {{1, 1}, {1, 5}, _}, :name},
        {:., {1, 5, nil}},
        {:paren_identifier, {{1, 6}, {1, 8}, _}, :"::"},
        {:"(", {1, 8, nil}},
        {:int, {{1, 9}, {1, 10}, 3}, ~c"3"},
        {:")", {1, 10, nil}}
      ], tokens)
    end

    test "arithmetic" do
      assert tokenize("1 + 2 + 3") == {:ok, [
        {:int, {{1, 1}, {1, 2}, 1}, ~c"1"},
        # TODO: range is invalid
        {:dual_op, {{1, 3}, {1, 4}, nil}, :+},
        {:int, {{1, 5}, {1, 6}, 2}, ~c"2"},
        {:dual_op, {{1, 7}, {1, 8}, nil}, :+},
        {:int, {{1, 9}, {1, 10}, 3}, ~c"3"}
      ], ""}
    end

    test "op_kw" do
      {:ok, tokens, ""} = tokenize(":foo+:bar")
      assert match?([
        {:atom, {{1, 1}, {1, 5}, _}, :foo},
        {:dual_op, {{1, 5}, {1, 6}, nil}, :+},
        {:atom, {{1, 6}, {1, 10}, _}, :bar}
      ], tokens)
    end

    test "scientific" do
      assert tokenize("1.0e-1") == {:ok, [
        {:flt, {{1, 1}, {1, 7}, 0.1}, ~c"1.0e-1"}
      ], ""}

      assert tokenize("1.0E-1") == {:ok, [
        {:flt, {{1, 1}, {1, 7}, 0.1}, ~c"1.0E-1"}
      ], ""}

      assert tokenize("1_234.567_8e-10") == {:ok, [
        {:flt, {{1, 1}, {1, 16}, 1.2345678e-7}, ~c"1_234.567_8e-10"}
      ], ""}
    end

    test "hex_bin_octal" do
      assert tokenize("0xFF") == {:ok, [
        {:int, {{1, 1}, {1, 5}, 255}, ~c"0xFF"}
      ], ""}

      assert tokenize("0xF_F") == {:ok, [
        {:int, {{1, 1}, {1, 6}, 255}, ~c"0xF_F"}
      ], ""}

      assert tokenize("0o77") == {:ok, [
        {:int, {{1, 1}, {1, 5}, 63}, ~c"0o77"}
      ], ""}

      assert tokenize("0o7_7") == {:ok, [
        {:int, {{1, 1}, {1, 6}, 63}, ~c"0o7_7"}
      ], ""}

      assert tokenize("0b11") == {:ok, [
        {:int, {{1, 1}, {1, 5}, 3}, ~c"0b11"}
      ], ""}

      assert tokenize("0b1_1") == {:ok, [
        {:int, {{1, 1}, {1, 6}, 3}, ~c"0b1_1"}
      ], ""}
    end

    test "unquoted_atom" do
      {:ok, tokens, ""} = tokenize(":+")
      assert match?([{:atom, {{1, 1}, {1, 3}, _}, :+}], tokens)

      {:ok, tokens, ""} = tokenize(":-")
      assert match?([{:atom, {{1, 1}, {1, 3}, _}, :-}], tokens)

      {:ok, tokens, ""} = tokenize(":*")
      assert match?([{:atom, {{1, 1}, {1, 3}, _}, :*}], tokens)

      {:ok, tokens, ""} = tokenize(":/")
      assert match?([{:atom, {{1, 1}, {1, 3}, _}, :/}], tokens)

      {:ok, tokens, ""} = tokenize(":=")
      assert match?([{:atom, {{1, 1}, {1, 3}, _}, :=}], tokens)

      {:ok, tokens, ""} = tokenize(":&&")
      assert match?([{:atom, {{1, 1}, {1, 4}, _}, :"&&"}], tokens)
    end

    test "quoted_atom" do
      assert tokenize(":\"foo bar\"") == {:ok, [
        {:atom_quoted, {{1, 1}, {1, 11}, ?\"}, :"foo bar"}
      ], ""}
    end

    test "op_atom" do
      {:ok, tokens, ""} = tokenize(":f0_1")
      assert match?([{:atom, {{1, 1}, {1, 6}, _}, :f0_1}], tokens)
    end

    test "kw" do
      {:ok, tokens, ""} = tokenize("do: ")
      assert match?([{:kw_identifier, {{1, 1}, {1, 4}, _}, :do}], tokens)

      {:ok, tokens, ""} = tokenize("a@: ")
      assert match?([{:kw_identifier, {{1, 1}, {1, 4}, _}, :a@}], tokens)

      {:ok, tokens, ""} = tokenize("A@: ")
      assert match?([{:kw_identifier, {{1, 1}, {1, 4}, _}, :"A@"}], tokens)

      {:ok, tokens, ""} = tokenize("a@b: ")
      assert match?([{:kw_identifier, {{1, 1}, {1, 5}, _}, :a@b}], tokens)

      {:ok, tokens, ""} = tokenize("A@!: ")
      assert match?([{:kw_identifier, {{1, 1}, {1, 5}, _}, :"A@!"}], tokens)

      {:ok, tokens, ""} = tokenize("a@!: ")
      assert match?([{:kw_identifier, {{1, 1}, {1, 5}, _}, :"a@!"}], tokens)

      {:ok, tokens, ""} = tokenize("foo: \"bar\"")
      assert match?([
        {:kw_identifier, {{1, 1}, {1, 5}, _}, :foo},
        {:bin_string, {{1, 6}, {1, 11}, nil}, [<<"bar">>]}
      ], tokens)

      {:ok, tokens, ""} = tokenize("\"+\": \"bar\"")
      assert match?([
        {:kw_identifier, {{1, 1}, {1, 5}, _}, :+},
        {:bin_string, {{1, 6}, {1, 11}, nil}, [<<"bar">>]}
      ], tokens)
    end

    test "int" do
      assert tokenize("123") == {:ok, [
        {:int, {{1, 1}, {1, 4}, 123}, ~c"123"}
      ], ""}

      assert tokenize("123;") == {:ok, [
        {:int, {{1, 1}, {1, 4}, 123}, ~c"123"},
        {:";", {{1, 4}, {1, 5}, 0}}
      ], ""}

      assert tokenize("\n\n123") == {:ok, [
        {:eol, {1, 1, 2}},
        {:int, {{3, 1}, {3, 4}, 123}, ~c"123"}
      ], ""}

      assert tokenize("  123  234  ") == {:ok, [
        {:int, {{1, 3}, {1, 6}, 123}, ~c"123"},
        {:int, {{1, 8}, {1, 11}, 234}, ~c"234"}
      ], ""}

      assert tokenize("007") == {:ok, [
        {:int, {{1, 1}, {1, 4}, 7}, ~c"007"}
      ], ""}

      assert tokenize("0100000") == {:ok, [
        {:int, {{1, 1}, {1, 8}, 100000}, ~c"0100000"}
      ], ""}
    end

    test "float" do
      assert tokenize("12.3") == {:ok, [
        {:flt, {{1, 1}, {1, 5}, 12.3}, ~c"12.3"}
      ], ""}

      assert tokenize("12.3;") == {:ok, [
        {:flt, {{1, 1}, {1, 5}, 12.3}, ~c"12.3"},
        {:";", {{1, 5}, {1, 6}, 0}}
      ], ""}

      assert tokenize("\n\n12.3") == {:ok, [
        {:eol, {1, 1, 2}},
        {:flt, {{3, 1}, {3, 5}, 12.3}, ~c"12.3"}
      ], ""}

      assert tokenize("  12.3  23.4  ") == {:ok, [
        {:flt, {{1, 3}, {1, 7}, 12.3}, ~c"12.3"},
        {:flt, {{1, 9}, {1, 13}, 23.4}, ~c"23.4"}
      ], ""}

      assert tokenize("00_12.3_00") == {:ok, [
        {:flt, {{1, 1}, {1, 11}, 12.3}, ~c"00_12.3_00"}
      ], ""}
    end

    test "identifier" do
      {:ok, tokens, ""} = tokenize("abc ")
      assert match?([{:identifier, {{1, 1}, {1, 4}, _}, :abc}], tokens)

      {:ok, tokens, ""} = tokenize("abc?")
      assert match?([{:identifier, {{1, 1}, {1, 5}, _}, :abc?}], tokens)

      {:ok, tokens, ""} = tokenize("abc!")
      assert match?([{:identifier, {{1, 1}, {1, 5}, _}, :abc!}], tokens)

      {:ok, tokens, ""} = tokenize("a0c!")
      assert match?([{:identifier, {{1, 1}, {1, 5}, _}, :a0c!}], tokens)

      {:ok, tokens, ""} = tokenize("a0c()")
      assert match?([
        {:paren_identifier, {{1, 1}, {1, 4}, _}, :a0c},
        {:"(", {{1, 4}, {1, 5}, nil}},
        {:")", {{1, 5}, {1, 6}, nil}}
      ], tokens)

      {:ok, tokens, ""} = tokenize("a0c!()")
      assert match?([
        {:paren_identifier, {{1, 1}, {1, 5}, _}, :a0c!},
        {:"(", {{1, 5}, {1, 6}, nil}},
        {:")", {{1, 6}, {1, 7}, nil}}
      ], tokens)
    end

    test "module_macro" do
      {:ok, tokens, ""} = tokenize("__MODULE__")
      assert match?([{:identifier, {{1, 1}, {1, 11}, _}, :__MODULE__}], tokens)
    end

    test "dot" do
      {:ok, tokens, ""} = tokenize("foo.bar.baz")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:., {{1, 4}, {1, 5}, nil}},
        {:identifier, {{1, 5}, {1, 8}, _}, :bar},
        {:., {{1, 8}, {1, 9}, nil}},
        {:identifier, {{1, 9}, {1, 12}, _}, :baz}
      ], tokens)
    end

    test "dot_keyword" do
      {:ok, tokens, ""} = tokenize("foo.do")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:., {{1, 4}, {1, 5}, nil}},
        {:identifier, {{1, 5}, {1, 7}, _}, :do}
      ], tokens)
    end

    test "newline" do
      {:ok, tokens, ""} = tokenize("foo\n.bar")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:., {{2, 1}, {2, 2}, nil}},
        {:identifier, {{2, 2}, {2, 5}, _}, :bar}
      ], tokens)

      assert tokenize("1\n++2") == {:ok, [
        {:int, {{1, 1}, {1, 2}, 1}, ~c"1"},
        {:concat_op, {{2, 1}, {2, 3}, 1}, :"++"},
        {:int, {{2, 3}, {2, 4}, 2}, ~c"2"}
      ], ""}
    end

    test "dot_newline_operator" do
      {:ok, tokens, ""} = tokenize("foo.\n+1")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:., {{1, 4}, {1, 5}, nil}},
        {:identifier, {{2, 1}, {2, 2}, _}, :+},
        {:int, {{2, 2}, {2, 3}, 1}, ~c"1"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("foo.#bar\n+1")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:., {{1, 4}, {1, 5}, nil}},
        {:identifier, {{2, 1}, {2, 2}, _}, :+},
        {:int, {{2, 2}, {2, 3}, 1}, ~c"1"}
      ], tokens)
    end

    test "dot_call_operator" do
      {:ok, tokens, ""} = tokenize("f.()")
      assert match?([
        {:identifier, {{1, 1}, {1, 2}, _}, :f},
        {:dot_call_op, {{1, 2}, {1, 3}, nil}, :.},
        {:"(", {{1, 3}, {1, 4}, nil}},
        {:")", {{1, 4}, {1, 5}, nil}}
      ], tokens)
    end

    test "aliases" do
      {:ok, tokens, ""} = tokenize("Foo")
      assert match?([{:alias, {{1, 1}, {1, 4}, _}, :Foo}], tokens)

      {:ok, tokens, ""} = tokenize("Foo.Bar.Baz")
      assert match?([
        {:alias, {{1, 1}, {1, 4}, _}, :Foo},
        {:., {{1, 4}, {1, 5}, nil}},
        {:alias, {{1, 5}, {1, 8}, _}, :Bar},
        {:., {{1, 8}, {1, 9}, nil}},
        {:alias, {{1, 9}, {1, 12}, _}, :Baz}
      ], tokens)

      # TODO add dot tests with spaces
    end

    test "string" do
      assert tokenize("\"foo\"") == {:ok, [
        {:bin_string, {{1, 1}, {1, 6}, nil}, [<<"foo">>]}
      ], ""}

      assert tokenize("\"f\\\"\"") == {:ok, [
        {:bin_string, {{1, 1}, {1, 6}, nil}, [<<"f\"">>]}
      ], ""}
    end

    test "heredoc" do
      assert tokenize("\"\"\"\nheredoc\n\"\"\"") == {:ok, [
        {:bin_heredoc, {{1, 1}, {3, 4}, nil}, 0, [<<"heredoc\n">>]}
      ], ""}

      assert tokenize("\"\"\"\n heredoc\n \"\"\";") == {:ok, [
        {:bin_heredoc, {{1, 1}, {3, 5}, nil}, 1, [<<"heredoc\n">>]},
        {:";", {{3, 5}, {3, 6}, 0}}
      ], ""}
    end

    test "empty_string" do
      assert tokenize("\"\"") == {:ok, [
        {:bin_string, {{1, 1}, {1, 3}, nil}, [<<>>]}
      ], ""}
    end

    test "concat" do
      {:ok, tokens, ""} = tokenize("x ++ y")
      assert match?([
        {:identifier, {{1, 1}, {1, 2}, _}, :x},
        # TODO: range is invalid
        {:concat_op, {{1, 3}, {1, 5}, nil}, :"++"},
        {:identifier, {{1, 6}, {1, 7}, _}, :y}
      ], tokens)

      {:ok, tokens, ""} = tokenize("x +++ y")
      assert match?([
        {:identifier, {{1, 1}, {1, 2}, _}, :x},
        {:concat_op, {{1, 3}, {1, 6}, nil}, :"+++"},
        {:identifier, {{1, 7}, {1, 8}, _}, :y}
      ], tokens)
    end

    test "space" do
      {:ok, tokens, ""} = tokenize("foo -2")
      assert match?([
        {:op_identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:dual_op, {1, 5, nil}, :-},
        {:int, {{1, 6}, {1, 7}, 2}, ~c"2"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("foo  -2")
      assert match?([
        {:op_identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:dual_op, {1, 6, nil}, :-},
        {:int, {{1, 7}, {1, 8}, 2}, ~c"2"}
      ], tokens)
    end

    test "op_identifier with plus" do
      {:ok, tokens, ""} = tokenize("foo +2")
      assert match?([
        {:op_identifier, {{1, 1}, {1, 4}, _}, :foo},
        # TODO: no range on dual_op
        {:dual_op, {{1, 5}, {1, 6}, nil}, :+},
        {:int, {{1, 6}, {1, 7}, 2}, ~c"2"}
      ], tokens)
    end

    test "identifier with newline (vertical space) prevents op_identifier" do
      {:ok, tokens, ""} = tokenize("foo +\n2")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:dual_op, {{1, 5}, {1, 6}, nil}, :+},
        {:eol, {1, 6, 1}},
        {:int, {{2, 1}, {2, 2}, 2}, ~c"2"}
      ], tokens)
    end

    test "identifier with space before dual_op" do
      {:ok, tokens, ""} = tokenize("foo - 2")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:dual_op, {{1, 5}, {1, 6}, nil}, :-},
        {:int, {{1, 7}, {1, 8}, 2}, ~c"2"}
      ], tokens)
    end

    test "identifier when dual_op followed by colon space" do
      # +: becomes a kw_identifier in Elixir
      {:ok, tokens, ""} = tokenize("foo +: bar")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:kw_identifier, {{1, 5}, {1, 7}, nil}, :+},
        {:identifier, {{1, 8}, {1, 11}, _}, :bar}
      ], tokens)
    end

    test "identifier when dual_op followed by slash" do
      {:ok, tokens, ""} = tokenize("foo +/2")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:identifier, {{1, 5}, {1, 6}, nil}, :+},
        {:mult_op, {{1, 6}, {1, 7}, nil}, :/},
        {:int, {{1, 7}, {1, 8}, 2}, ~c"2"}
      ], tokens)
    end

    test "identifier when dual_op followed by >" do
      # +> is tokenized as separate tokens in Elixir
      {:ok, tokens, ""} = tokenize("foo +>bar")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:dual_op, {{1, 5}, {1, 6}, nil}, :+},
        {:rel_op, {{1, 6}, {1, 7}, nil}, :>},
        {:identifier, {{1, 7}, {1, 10}, _}, :bar}
      ], tokens)
    end

    test "identifier when dual_op repeated" do
      {:ok, tokens, ""} = tokenize("foo ++bar")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:concat_op, {{1, 5}, {1, 7}, nil}, :++},
        {:identifier, {{1, 7}, {1, 10}, _}, :bar}
      ], tokens)

      {:ok, tokens, ""} = tokenize("foo --bar")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:concat_op, {{1, 5}, {1, 7}, nil}, :--},
        {:identifier, {{1, 7}, {1, 10}, _}, :bar}
      ], tokens)
    end

    test "not op_identifier with other operators" do
      {:ok, tokens, ""} = tokenize("foo *2")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:mult_op, {{1, 5}, {1, 6}, nil}, :*},
        {:int, {{1, 6}, {1, 7}, 2}, ~c"2"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("foo /2")
      assert match?([
        {:identifier, {{1, 1}, {1, 4}, _}, :foo},
        {:mult_op, {{1, 5}, {1, 6}, nil}, :/},
        {:int, {{1, 6}, {1, 7}, 2}, ~c"2"}
      ], tokens)
    end

    test "closing parenthesis after newline" do
      # When there's a newline before closing paren, it should have a count
      assert tokenize("foo(\n)") == {:ok, [
        {:paren_identifier, {{1, 1}, {1, 4}, ~c"foo"}, :foo},
        {:"(", {{1, 4}, {1, 5}, nil}},
        {:eol, {1, 5, 1}},
        {:")", {{2, 1}, {2, 2}, 1}}
      ], ""}

      # Without newline, closing paren should have nil
      assert tokenize("foo()") == {:ok, [
        {:paren_identifier, {{1, 1}, {1, 4}, ~c"foo"}, :foo},
        {:"(", {{1, 4}, {1, 5}, nil}},
        {:")", {{1, 5}, {1, 6}, nil}}
      ], ""}

      # Same for brackets
      assert tokenize("[1\n]") == {:ok, [
        {:"[", {{1, 1}, {1, 2}, nil}},
        {:int, {{1, 2}, {1, 3}, 1}, ~c"1"},
        {:eol, {1, 3, 1}},
        {:"]", {{2, 1}, {2, 2}, 1}}
      ], ""}

      # And braces
      assert tokenize("{:ok\n}") == {:ok, [
        {:"{", {{1, 1}, {1, 2}, nil}},
        {:atom, {{1, 2}, {1, 5}, ~c"ok"}, :ok},
        {:eol, {1, 5, 1}},
        {:"}", {{2, 1}, {2, 2}, 1}}
      ], ""}
    end

    test "closing parenthesis EOL tracking edge cases" do
      # Case from Atom module: spec with parens should have nil count
      assert tokenize("@spec foo(atom)") == {:ok, [
        {:at_op, {{1, 1}, {1, 2}, nil}, :@},
        {:identifier, {{1, 2}, {1, 6}, ~c"spec"}, :spec},
        {:paren_identifier, {{1, 7}, {1, 10}, ~c"foo"}, :foo},
        {:"(", {{1, 10}, {1, 11}, nil}},
        {:identifier, {{1, 11}, {1, 15}, ~c"atom"}, :atom},
        {:")", {{1, 15}, {1, 16}, nil}}
      ], ""}

      # Closing paren should not have count even if there's EOL earlier
      assert tokenize("foo\nbar(baz)") == {:ok, [
        {:identifier, {{1, 1}, {1, 4}, ~c"foo"}, :foo},
        {:eol, {1, 4, 1}},
        {:paren_identifier, {{2, 1}, {2, 4}, ~c"bar"}, :bar},
        {:"(", {{2, 4}, {2, 5}, nil}},
        {:identifier, {{2, 5}, {2, 8}, ~c"baz"}, :baz},
        {:")", {{2, 8}, {2, 9}, nil}}
      ], ""}
    end

    test "chars" do
      assert tokenize("?a") == {:ok, [
        {:char, {{1, 1}, {1, 3}, ~c"?a"}, 97}
      ], ""}

      assert tokenize("?c") == {:ok, [
        {:char, {{1, 1}, {1, 3}, ~c"?c"}, 99}
      ], ""}

      assert tokenize("?\\0") == {:ok, [
        {:char, {{1, 1}, {1, 4}, ~c"?\\0"}, 0}
      ], ""}

      assert tokenize("?\\a") == {:ok, [
        {:char, {{1, 1}, {1, 4}, ~c"?\\a"}, 7}
      ], ""}

      assert tokenize("?\\n") == {:ok, [
        {:char, {{1, 1}, {1, 4}, ~c"?\\n"}, 10}
      ], ""}

      assert tokenize("?\\\\") == {:ok, [
        {:char, {{1, 1}, {1, 4}, ~c"?\\\\"}, 92}
      ], ""}
    end

    test "interpolation" do
      # Testing: "f#{oo}"
      # Expected result: bin_string with literal "f" and interpolation containing identifier oo
      code = ~S["f#{oo}"]
      {:ok, tokens, ""} = tokenize(code)
      assert match?([
        {:bin_string, {{1, 1}, {1, 9}, nil}, [
          <<"f">>,
          {{1, 3, nil}, {1, 7, nil}, [{:identifier, {{1, 5}, {1, 7}, _}, :oo}]}
        ]}
      ], tokens)
    end

    test "escaped_interpolation" do
      # Testing: "f\#{oo}"
      # Expected result: bin_string with literal "f#{oo}" (escaped interpolation)
      code = ~S["f\#{oo}"]
      assert tokenize(code) == {:ok, [
        {:bin_string, {{1, 1}, {1, 10}, nil}, [<<"f\#{oo}">>]}
      ], ""}
    end

    test "capture operators" do
      assert tokenize("&not 1, 2") == {:ok, [
        {:capture_op, {{1, 1}, {1, 2}, nil}, :"&"},
        {:unary_op, {{1, 2}, {1, 5}, nil}, :not},
        {:int, {{1, 6}, {1, 7}, 1}, ~c"1"},
        {:",", {{1, 7}, {1, 8}, 0}},
        {:int, {{1, 9}, {1, 10}, 2}, ~c"2"}
      ], ""}

      {:ok, tokens, ""} = tokenize("&||/2")
      assert match?([
        {:capture_op, {{1, 1}, {1, 2}, nil}, :"&"},
        {:identifier, {{1, 2}, {1, 4}, _}, :"||"},
        {:mult_op, {{1, 4}, {1, 5}, nil}, :/},
        {:int, {{1, 5}, {1, 6}, 2}, ~c"2"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("&or/2")
      assert match?([
        {:capture_op, {{1, 1}, {1, 2}, nil}, :"&"},
        # TODO: no range on or
        {:identifier, {{1, 2}, {1, 4}, _}, :or},
        {:mult_op, {{1, 4}, {1, 5}, nil}, :/},
        {:int, {{1, 5}, {1, 6}, 2}, ~c"2"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("& +/1")
      assert match?([
        {:capture_op, {1, 1, nil}, :"&"},
        {:identifier, {{1, 3}, {1, 4}, _}, :+},
        {:mult_op, {1, 4, nil}, :/},
        {:int, {{1, 5}, {1, 6}, 1}, ~c"1"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("& &/1")
      assert match?([
        {:capture_op, {1, 1, nil}, :"&"},
        {:identifier, {{1, 3}, {1, 4}, _}, :"&"},
        {:mult_op, {1, 4, nil}, :/},
        {:int, {{1, 5}, {1, 6}, 1}, ~c"1"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("& ..///3")
      assert match?([
        {:capture_op, {1, 1, nil}, :"&"},
        {:identifier, {{1, 3}, {1, 7}, _}, :"..//"},
        {:mult_op, {1, 7, nil}, :/},
        {:int, {1, 8, 3}, ~c"3"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("& / /2")
      assert match?([
        {:capture_op, {1, 1, nil}, :"&"},
        {:identifier, {1, 3, _}, :/},
        {:mult_op, {1, 5, nil}, :/},
        {:int, {1, 6, 2}, ~c"2"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("&/ /2")
      assert match?([
        {:capture_op, {1, 1, nil}, :"&"},
        {:identifier, {1, 2, _}, :/},
        {:mult_op, {1, 4, nil}, :/},
        {:int, {{1, 5}, {1, 6}, 2}, ~c"2"}
      ], tokens)

      # Only operators
      {:ok, tokens, ""} = tokenize("&/1")
      assert match?([
        {:identifier, {{1, 1}, {1, 2}, _}, :"&"},
        {:mult_op, {1, 2, nil}, :/},
        {:int, {{1, 3}, {1, 4}, 1}, ~c"1"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("+/1")
      assert match?([
        {:identifier, {1, 1, _}, :+},
        {:mult_op, {1, 2, nil}, :/},
        {:int, {{1, 3}, {1, 4}, 1}, ~c"1"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("/ /2")
      assert match?([
        {:identifier, {{1, 1}, {1, 2}, _}, :/},
        {:mult_op, {1, 3, nil}, :/},
        {:int, {{1, 4}, {1, 5}, 2}, ~c"2"}
      ], tokens)

      {:ok, tokens, ""} = tokenize("..///3")
      assert match?([
        {:identifier, {{1, 1}, {1, 5}, _}, :"..//"},
        {:mult_op, {1, 5, nil}, :/},
        {:int, {{1, 6}, {1, 7}, 3}, ~c"3"}
      ], tokens)
    end

    test "sigil_terminator" do
      assert tokenize("~r/foo/") == {:ok, [
        {:sigil, {{1, 1}, {1, 8}, nil}, :sigil_r, [<<"foo">>], [], nil, <<"/">>}
      ], ""}

      assert tokenize("~r[foo]") == {:ok, [
        {:sigil, {{1, 1}, {1, 8}, nil}, :sigil_r, [<<"foo">>], [], nil, <<"[">>}
      ], ""}

      assert tokenize("~r\"foo\"") == {:ok, [
        {:sigil, {{1, 1}, {1, 8}, nil}, :sigil_r, [<<"foo">>], [], nil, <<"\"">>}
      ], ""}

      {:ok, tokens, ""} = tokenize("~r/foo/ == bar")
      assert match?([
        {:sigil, {{1, 1}, {1, 8}, nil}, :sigil_r, [<<"foo">>], [], nil, <<"/">>},
        # TODO: range is invalid
        {:comp_op, {{1, 9}, {1, 11}, nil}, :"=="},
        {:identifier, {{1, 12}, {1, 15}, _}, :bar}
      ], tokens)

      {:ok, tokens, ""} = tokenize("~r/foo/iu == bar")
      assert match?([
        {:sigil, {1, 1, nil}, :sigil_r, [<<"foo">>], ~c"iu", nil, <<"/">>},
        {:comp_op, {1, 11, nil}, :"=="},
        {:identifier, {{1, 14}, {1, 17}, _}, :bar}
      ], tokens)

      assert tokenize("~M[1 2 3]u8") == {:ok, [
        {:sigil, {1, 1, nil}, :sigil_M, [<<"1 2 3">>], ~c"u8", nil, <<"[">>}
      ], ""}
    end

    test "sigil_heredoc" do
      assert tokenize("~S\"\"\"\nsigil heredoc\n\"\"\"") == {:ok, [
        {:sigil, {{1, 1}, {3, 4}, nil}, :sigil_S, [<<"sigil heredoc\n">>], [], 0, <<"\"\"\"">>}
      ], ""}

      assert tokenize("~S'''\nsigil heredoc\n'''") == {:ok, [
        {:sigil, {{1, 1}, {3, 4}, nil}, :sigil_S, [<<"sigil heredoc\n">>], [], 0, <<"'''">>}
      ], ""}

      assert tokenize("~S\"\"\"\n  sigil heredoc\n  \"\"\"") == {:ok, [
        {:sigil, {{1, 1}, {3, 6}, nil}, :sigil_S, [<<"sigil heredoc\n">>], [], 2, <<"\"\"\"">>}
      ], ""}

      assert tokenize("~s\"\"\"\n  sigil heredoc\n  \"\"\"") == {:ok, [
        {:sigil, {{1, 1}, {3, 6}, nil}, :sigil_s, [<<"sigil heredoc\n">>], [], 2, <<"\"\"\"">>}
      ], ""}
    end

    # Note: vc_merge_conflict_test is skipped as it tests tokenize_error
    # Note: invalid_sigil_delimiter_test is skipped as it tests tokenize_error
  end
end
