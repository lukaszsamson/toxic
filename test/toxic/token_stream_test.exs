defmodule Toxic.TokenStreamTest do
  use ExUnit.Case
  alias Toxic.TokenStream

  describe "new/4" do
    test "creates a stream from a binary source" do
      stream = TokenStream.new("1 + 2")
      assert %TokenStream{driver: %Toxic.Driver{}} = stream
    end

    test "creates a stream with custom starting position" do
      stream = TokenStream.new("foo", 5, 10)
      {{line, column}, _} = TokenStream.position(stream)
      assert line == 5
      assert column == 10
    end

    test "accepts options" do
      stream = TokenStream.new("foo", 1, 1, max_batch: 10)
      assert stream.opts[:max_batch] == 10
    end

    test "accepts a function source" do
      source = fn _line, _column -> :eof end
      stream = TokenStream.new(source)
      assert %TokenStream{} = stream
    end
  end

  describe "next/1" do
    test "returns tokens in order" do
      stream = TokenStream.new("1 + 2")

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token1

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token2

      {:ok, token3, stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token3

      assert {:eof, _} = TokenStream.next(stream)
    end

    test "handles empty input" do
      stream = TokenStream.new("")
      assert {:eof, _} = TokenStream.next(stream)
    end

    test "handles non empty input with no tokens" do
      stream = TokenStream.new(" ")
      assert {:eof, _} = TokenStream.next(stream)
    end

    test "handles string interpolation with linearized tokens" do
      stream = TokenStream.new(~s("foo \#{1 + 2} bar"))

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:bin_string_start, {{1, 1}, {1, 2}, nil}, 34} = token1

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:string_fragment, _, "foo "} = token2

      {:ok, token3, stream} = TokenStream.next(stream)
      assert {:begin_interpolation, _, :string} = token3

      {:ok, token4, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = token4

      {:ok, token5, stream} = TokenStream.next(stream)
      assert {:dual_op, _, :+} = token5

      {:ok, token6, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"2"} = token6

      {:ok, token7, stream} = TokenStream.next(stream)
      assert {:end_interpolation, _, :string} = token7

      {:ok, token8, stream} = TokenStream.next(stream)
      assert {:string_fragment, _, " bar"} = token8

      {:ok, token9, stream} = TokenStream.next(stream)
      assert {:bin_string_end, {{1, 18}, {1, 19}, nil}, 34} = token9

      assert {:eof, _} = TokenStream.next(stream)
    end
  end

  describe "peek/1" do
    test "returns next token without consuming" do
      stream = TokenStream.new("1 + 2")

      {:ok, token, stream1} = TokenStream.peek(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token

      # Peek again returns the same token
      {:ok, token, stream2} = TokenStream.peek(stream1)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token

      # Stream state unchanged
      assert stream1 == stream2

      # Next consumes the token
      {:ok, token, stream3} = TokenStream.next(stream2)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token

      # Now peek returns the next token
      {:ok, token, _stream4} = TokenStream.peek(stream3)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token
    end

    test "peek forcing token fetch resulting in eof signal" do
      stream = TokenStream.new("1 + 2", 1, 1, max_batch: 3)

      # This will fetch a new batch
      {:ok, token, stream} = TokenStream.peek(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token

      # Next consumes the tokens
      {:ok, _token, stream} = TokenStream.next(stream)
      {:ok, _token, stream} = TokenStream.next(stream)
      {:ok, _token, stream} = TokenStream.next(stream)

      # This will fetch a new batch and return eof
      assert {:eof, _} = TokenStream.peek(stream)
    end

    test "peek forcing token fetch returning non full batch" do
      stream = TokenStream.new("1 + 2", 1, 1, max_batch: 4)

      # This will fetch a new batch
      {:ok, token, stream} = TokenStream.peek(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token

      # Next consumes the tokens
      {:ok, _token, stream} = TokenStream.next(stream)
      {:ok, _token, stream} = TokenStream.next(stream)
      {:ok, _token, stream} = TokenStream.next(stream)

      # This will return eof
      assert {:eof, _} = TokenStream.peek(stream)
    end

    test "handles EOF" do
      stream = TokenStream.new("")
      assert {:eof, _} = TokenStream.peek(stream)
    end
  end

  describe "peek_n/2" do
    test "returns multiple tokens without consuming" do
      stream = TokenStream.new("1 + 2 * 3")

      {:ok, tokens, stream1} = TokenStream.peek_n(stream, 3)

      assert [
               {:int, {{1, 1}, {1, 2}, 1}, ~c"1"},
               {:dual_op, {{1, 3}, {1, 4}, _}, :+},
               {:int, {{1, 5}, {1, 6}, 2}, ~c"2"}
             ] = tokens

      # Can still get first token
      {:ok, token, _} = TokenStream.next(stream1)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token
    end

    test "returns fewer tokens at EOF" do
      stream = TokenStream.new("1 +")

      {:eof, tokens, _stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 2
    end

    test "returns tokens to EOF" do
      stream = TokenStream.new("1 +")

      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 2)
      assert length(tokens) == 2
    end

    test "forces fetching a correct number of batches" do
      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 2)

      # This will fetch 2 times
      {:ok, tokens, stream} = TokenStream.peek_n(stream, 4)
      assert length(tokens) == 4

      {:eof, tokens, _stream} = TokenStream.peek_n(stream, 6)
      assert length(tokens) == 5

      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 2)

      # This will fetch 3 times
      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 5

      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 5)

      # This will fetch 1 time
      {:ok, tokens, stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 5

      {:eof, tokens, _stream} = TokenStream.peek_n(stream, 6)
      assert length(tokens) == 5
    end

    test "raises for n <= 0" do
      stream = TokenStream.new("1 + 2")
      assert_raise ArgumentError, fn -> TokenStream.peek_n(stream, 0) end
    end
  end

  describe "pushback/2" do
    test "pushes token back for next consumption" do
      stream = TokenStream.new("1 + 2")

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token1

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token2

      # Push back the operator
      stream = TokenStream.pushback(stream, token2)

      # Next returns the pushed back token
      {:ok, token, stream} = TokenStream.next(stream)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token

      # Continue normally
      {:ok, token, _stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token
    end

    test "multiple pushbacks work in LIFO order" do
      stream = TokenStream.new("1")

      {:ok, token1, stream} = TokenStream.next(stream)

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}
      fake_token2 = {:fake2, {{1, 2}, {1, 3}, nil}, nil}

      stream =
        stream
        |> TokenStream.pushback(token1)
        |> TokenStream.pushback(fake_token1)
        |> TokenStream.pushback(fake_token2)

      {:ok, t1, stream} = TokenStream.next(stream)
      assert t1 == fake_token2

      {:ok, t2, stream} = TokenStream.next(stream)
      assert t2 == fake_token1

      {:ok, t3, _stream} = TokenStream.next(stream)
      assert t3 == token1
    end

    test "pushback and peek" do
      stream = TokenStream.new("")

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}

      stream =
        stream
        |> TokenStream.pushback(fake_token1)

      {:ok, token, _stream} = TokenStream.peek(stream)

      assert token == fake_token1
    end

    test "pushback and peek at eof" do
      stream = TokenStream.new("")

      {:eof, stream} = TokenStream.next(stream)

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}

      stream =
        stream
        |> TokenStream.pushback(fake_token1)

      {:ok, token, _stream} = TokenStream.peek(stream)

      assert token == fake_token1
    end

    test "pushback and peek_n push >= n" do
      stream = TokenStream.new("")

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}
      fake_token2 = {:fake2, {{1, 1}, {1, 2}, nil}, nil}

      stream =
        stream
        |> TokenStream.pushback(fake_token1)
        |> TokenStream.pushback(fake_token2)

      {:ok, [token1, token2], _stream} = TokenStream.peek_n(stream, 2)

      assert token1 == fake_token2
      assert token2 == fake_token1
    end

    test "pushback and peek_n push < n" do
      stream = TokenStream.new("1")

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}
      fake_token2 = {:fake2, {{1, 1}, {1, 2}, nil}, nil}

      stream =
        stream
        |> TokenStream.pushback(fake_token1)
        |> TokenStream.pushback(fake_token2)

      {:ok, [token1, token2, token3], _stream} = TokenStream.peek_n(stream, 3)

      assert token1 == fake_token2
      assert token2 == fake_token1
      assert token3 == {:int, {{1, 1}, {1, 2}, 1}, ~c"1"}
    end

    test "pushback and peek_n at eof" do
      stream = TokenStream.new("1")

      {:ok, _, stream} = TokenStream.next(stream)

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}
      fake_token2 = {:fake2, {{1, 1}, {1, 2}, nil}, nil}

      stream =
        stream
        |> TokenStream.pushback(fake_token1)
        |> TokenStream.pushback(fake_token2)

      {:eof, [^fake_token2, ^fake_token1], _stream} = TokenStream.peek_n(stream, 3)
    end

    test "peek_n at eof, buffered token" do
      stream = TokenStream.new("1")

      {:ok, token, stream} = TokenStream.peek(stream)

      {:eof, [^token], _stream} = TokenStream.peek_n(stream, 3)
    end
  end

  describe "checkpoint/1 and rewind_to/2" do
    test "can create checkpoint and rewind" do
      stream = TokenStream.new("1 + 2 * 3")

      {:ok, _token1, stream} = TokenStream.next(stream)
      {:ok, _token2, stream} = TokenStream.next(stream)

      # Create checkpoint after consuming 2 tokens
      {ref, stream} = TokenStream.checkpoint(stream)

      # Consume more tokens
      {:ok, _token3, stream} = TokenStream.next(stream)
      {:ok, _token4, stream} = TokenStream.next(stream)

      # Rewind to checkpoint
      stream = TokenStream.rewind_to(stream, ref)

      # Should be back at position after first 2 tokens
      {:ok, token, _stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token
    end

    test "invalid checkpoint raises error" do
      stream = TokenStream.new("1")
      fake_ref = make_ref()

      assert_raise ArgumentError, ~r/Invalid checkpoint reference/, fn ->
        TokenStream.rewind_to(stream, fake_ref)
      end
    end
  end

  describe "position/1" do
    test "returns current position" do
      stream = TokenStream.new("1\n  2")

      {{line, col}, stream} = TokenStream.position(stream)
      assert line == 1
      assert col == 1

      # Consume first token
      {:ok, _token, stream} = TokenStream.next(stream)

      # Position should be updated
      {{line, col}, _stream} = TokenStream.position(stream)
      assert line == 1
      assert col == 2
    end
  end

  describe "position at EOF" do
    test "returns end position of last token" do
      stream = TokenStream.new("1 + 2")

      # Consume all tokens, remember last token end position
      {last_end_pos, stream} =
        Stream.unfold(stream, fn s ->
          case TokenStream.next(s) do
            {:ok, token, s2} ->
              end_pos =
                case token do
                  {_, {{_sl, _sc}, {el, ec}, _extra}, _rest} -> {el, ec}
                  {_, {{_sl, _sc}, {el, ec}, _extra}} -> {el, ec}
                  _ -> nil
                end

              {{end_pos, s2}, s2}

            {:eof, _s2} ->
              nil
          end
        end)
        |> Enum.reduce({nil, stream}, fn {end_pos, s}, {_acc, _} -> {end_pos, s} end)

      # At EOF, position should match last token's end position
      {{line, col}, _} = TokenStream.position(stream)
      assert {line, col} == last_end_pos
    end
  end

  describe "position with batching and pushback" do
    test "position reflects buffer head under batching" do
      stream = TokenStream.new("1 + 2", 1, 1, max_batch: 1)
      # Initial position at first token
      {{l1, c1}, stream} = TokenStream.position(stream)
      assert {l1, c1} == {1, 1}

      # Peek should not advance position
      {:ok, _t, stream} = TokenStream.peek(stream)
      {{l2, c2}, stream} = TokenStream.position(stream)
      assert {l2, c2} == {1, 1}

      # After consuming first token ("1"), next token is '+' at col 3
      {:ok, _t1, stream} = TokenStream.next(stream)
      {{l3, c3}, _stream} = TokenStream.position(stream)
      assert {l3, c3} == {1, 3}
    end

    test "position restores on pushback" do
      stream = TokenStream.new("1 + 2")

      # Take first token and remember its pre-position
      {{pos_before_first_l, pos_before_first_c}, stream} = TokenStream.position(stream)
      {:ok, t1, stream} = TokenStream.next(stream)
      # Now position should be before '+'
      {{l_after, c_after}, stream} = TokenStream.position(stream)
      assert {l_after, c_after} == {1, 3}

      # Push back t1; position should revert to the remembered pre-position
      stream = TokenStream.pushback(stream, t1)
      {{l_re, c_re}, _} = TokenStream.position(stream)
      assert {l_re, c_re} == {pos_before_first_l, pos_before_first_c}
    end

    test "peek does not change position across batches" do
      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 2)
      {{l0, c0}, stream} = TokenStream.position(stream)
      assert {l0, c0} == {1, 1}

      # Force a refill by peeking multiple times
      {:ok, _t, stream} = TokenStream.peek(stream)
      {:ok, _t, stream} = TokenStream.peek_n(stream, 5)
      {{lA, cA}, _} = TokenStream.position(stream)
      assert {lA, cA} == {1, 1}
    end
  end

  describe "to_stream/1" do
    test "converts to Elixir stream" do
      stream = TokenStream.new("1 + 2 * 3")

      tokens =
        stream
        |> TokenStream.to_stream()
        |> Enum.to_list()

      assert [
               {:int, {{1, 1}, {1, 2}, 1}, ~c"1"},
               {:dual_op, {{1, 3}, {1, 4}, _}, :+},
               {:int, {{1, 5}, {1, 6}, 2}, ~c"2"},
               {:mult_op, {{1, 7}, {1, 8}, _}, :*},
               {:int, {{1, 9}, {1, 10}, 3}, ~c"3"}
             ] = tokens
    end

    test "converts to Elixir stream with small batch size" do
      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 2)

      tokens =
        stream
        |> TokenStream.to_stream()
        |> Enum.to_list()

      assert [
               {:int, {{1, 1}, {1, 2}, 1}, ~c"1"},
               {:dual_op, {{1, 3}, {1, 4}, _}, :+},
               {:int, {{1, 5}, {1, 6}, 2}, ~c"2"},
               {:mult_op, {{1, 7}, {1, 8}, _}, :*},
               {:int, {{1, 9}, {1, 10}, 3}, ~c"3"}
             ] = tokens
    end

    test "handles empty input" do
      stream = TokenStream.new("")
      tokens = stream |> TokenStream.to_stream() |> Enum.to_list()
      assert tokens == []
    end
  end

  describe "slice/6" do
    test "creates stream from slice of input" do
      source = "foo bar baz"
      stream = TokenStream.slice(source, 4, 7, 1, 5)

      {:ok, token, stream} = TokenStream.next(stream)
      assert {:identifier, {{1, 5}, {1, 8}, _}, :bar} = token

      assert {:eof, _} = TokenStream.next(stream)
    end
  end

  describe "current_terminators/1" do
    test "returns terminator stack" do
      stream = TokenStream.new("(")

      # Initially empty
      {terminators, stream} = TokenStream.current_terminators(stream)
      assert terminators == []

      # After consuming '(', would have paren terminator
      {:ok, _token, stream} = TokenStream.next(stream)

      {terms, _} = TokenStream.current_terminators(stream)
      assert match?([{:"(", _, _} | _], terms)
    end

    test "returns terminator stack at current position not batch end" do
      stream = TokenStream.new("(1)")

      # Initially empty
      {terminators, stream} = TokenStream.current_terminators(stream)
      assert terminators == []

      # After consuming '(', would have paren terminator
      {:ok, _token, stream} = TokenStream.next(stream)

      {terms, _} = TokenStream.current_terminators(stream)
      assert match?([{:"(", _, _} | _], terms)
    end

    test "respects pushed entry snapshot over driver" do
      stream = TokenStream.new("(")

      # Consume '('
      {:ok, tok, stream} = TokenStream.next(stream)

      # Driver now expects a closing paren, but we push back '('
      stream = TokenStream.pushback(stream, tok)

      # Terminators should reflect the state before '(', which is empty
      {terms, _} = TokenStream.current_terminators(stream)
      assert terms == []
    end

    test "falls back to driver terms when pushed token lacks snapshot" do
      stream = TokenStream.new("(")

      # Consume '('
      {:ok, _tok, stream} = TokenStream.next(stream)

      # Push a fake token (no snapshot in stream), so current_terminators should use driver
      fake = {:fake, {{1, 1}, {1, 1}, nil}, nil}
      stream = TokenStream.pushback(stream, fake)

      {terms, _} = TokenStream.current_terminators(stream)
      assert match?([{:"(", _, _} | _], terms)
    end

    test "falls back to driver terms when pushed token lacks snapshot - assert current position not batch end" do
      stream = TokenStream.new("(1)")

      # Consume '('
      {:ok, _tok, stream} = TokenStream.next(stream)

      # Push a fake token (no snapshot in stream), so current_terminators should use driver
      fake = {:fake, {{1, 1}, {1, 1}, nil}, nil}
      stream = TokenStream.pushback(stream, fake)

      {terms, _} = TokenStream.current_terminators(stream)
      assert match?([{:"(", _, _} | _], terms)
    end
  end

  describe "peek_missing_terminator/1" do
    test "no missing" do
      stream = TokenStream.new("")

      assert {nil, _stream} = TokenStream.peek_missing_terminator(stream)
    end

    @simple_cases [
      {:"(", :")"},
      {:"{", :"}"},
      {:"[", :"]"},
      {:"<<", :">>"}
    ]

    test "suggests closing delimiter in simple cases" do
      for {open, close} <- @simple_cases do
        stream = TokenStream.new("#{open}1 + 2")

        # Consume tokens
        {:ok, _paren, stream} = TokenStream.next(stream)
        {:ok, _one, stream} = TokenStream.next(stream)
        {:ok, _plus, stream} = TokenStream.next(stream)
        {:ok, _two, stream} = TokenStream.next(stream)

        {closer, _stream} = TokenStream.peek_missing_terminator(stream)

        assert closer == close
      end
    end

    test "suggests closing delimiter in fn" do
      stream = TokenStream.new("fn x -> ")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)
      {:ok, _plus, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :end
    end

    test "suggests closing delimiter in do block" do
      stream = TokenStream.new("try do\n")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :end
    end

    test "suggests closing delimiter in bin_string" do
      stream = TokenStream.new("\"foo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\""
    end

    test "suggests closing delimiter in bin_string empty" do
      stream = TokenStream.new("\"")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\""
    end

    test "suggests closing delimiter in bin_string empty escape" do
      stream = TokenStream.new("\"\\")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _fragment, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\""
    end

    test "suggests closing delimiter in list_string" do
      stream = TokenStream.new("'foo")

      # Consume tokens
      {:ok, _sigil_start, stream} = TokenStream.next(stream)
      {:ok, _fragment, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"'"
    end

    test "suggests closing delimiter in bin_heredoc" do
      stream = TokenStream.new("\"\"\"\nfoo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\"\"\""
    end

    test "suggests closing delimiter in list_heredoc" do
      stream = TokenStream.new("'''\nfoo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"'''"
    end

    test "suggests closing delimiter in double quoted atom" do
      stream = TokenStream.new(":\"foo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\""
    end

    test "suggests closing delimiter in single quoted atom" do
      stream = TokenStream.new(":'foo")

      # Consume tokens
      {:ok, _atom_start, stream} = TokenStream.next(stream)
      {:ok, _fragment, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"'"
    end

    test "suggests closing delimiter in double quoted identifier" do
      stream = TokenStream.new("K.\"foo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\""
    end

    test "suggests closing delimiter in single quoted identifier" do
      stream = TokenStream.new("K.'foo")

      # Consume tokens
      {:ok, _identifier, stream} = TokenStream.next(stream)
      {:ok, _dot, stream} = TokenStream.next(stream)
      {:ok, _quoted_start, stream} = TokenStream.next(stream)
      {:ok, _fragment, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"'"
    end

    @sigil_terminators [
      {:/, :/},
      {:<, :>},
      {:"\"", :"\""},
      {:"'", :"'"},
      {:"[", :"]"},
      {:"(", :")"},
      {:"{", :"}"},
      {:|, :|}
    ]
    test "suggests closing delimiter in sigil" do
      for {opening_terminator, closing_terminator} <- @sigil_terminators do
        stream = TokenStream.new("~x#{opening_terminator}foo")

        # Consume tokens
        {:ok, _paren, stream} = TokenStream.next(stream)
        {:ok, _one, stream} = TokenStream.next(stream)

        {closer, _stream} = TokenStream.peek_missing_terminator(stream)

        assert closer == closing_terminator
      end
    end

    test "suggests closing delimiter in bin_heredoc sigil" do
      stream = TokenStream.new("~x\"\"\"\nfoo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"\"\"\""
    end

    test "suggests closing delimiter in list_heredoc sigil" do
      stream = TokenStream.new("~x'''\nfoo")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"'''"
    end

    test "suggests closing delimiter in bin_string interpolation" do
      stream = TokenStream.new("\"foo\#{")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)
      {:ok, _begin, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :"}"
    end

    test "suggests closing delimiter in bin_string interpolation content" do
      stream = TokenStream.new("\"foo\#{(1 +")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)
      {:ok, _begin, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)
      {:ok, _plus, stream} = TokenStream.next(stream)

      {closer, _stream} = TokenStream.peek_missing_terminator(stream)

      assert closer == :")"
    end
  end

  describe "error handling" do
    @invalid_source "Ä"

    test "errors/1 collects error tokens without consuming stream" do
      stream = TokenStream.new("Ä 1", 1, 1, error_mode: :tolerant)

      {errors, stream_after} = TokenStream.errors(stream)

      assert [{_meta, %Toxic.Error{}}] = errors
      assert stream_after == stream

      assert {:ok, {:error_token, _, %Toxic.Error{}}, stream_after_error} =
               TokenStream.next(stream_after)

      assert {:ok, {:int, _, ~c"1"}, _} = TokenStream.next(stream_after_error)
    end

    test "strict next/1 returns error tuple and preserves reason" do
      stream = TokenStream.new(@invalid_source, 1, 1, error_mode: :strict)

      assert {:error, reason, stream_after} = TokenStream.next(stream)
      assert reason != nil
      assert stream_after.error == reason

      # Subsequent calls continue to return the same error without mutating the stream
      assert {:error, ^reason, ^stream_after} = TokenStream.next(stream_after)
    end

    test "strict next/1 returns error at eof" do
      stream = TokenStream.new("}", 1, 1, error_mode: :strict)

      assert {:error, reason, stream_after} = TokenStream.next(stream)
      assert reason != nil
      assert stream_after.error == reason

      # Subsequent calls continue to return the same error without mutating the stream
      assert {:error, ^reason, ^stream_after} = TokenStream.next(stream_after)
    end

    test "strict peek/1 reports reports error" do
      stream = TokenStream.new(@invalid_source, 1, 1, error_mode: :strict)

      assert {:error, _reason, stream_after} = TokenStream.peek(stream)
      # Peek should not clear the stored error
      assert stream_after.error != nil
    end

    test "strict peek/1 reports eof once an error is recorded" do
      stream = TokenStream.new(@invalid_source, 1, 1, error_mode: :strict)
      assert {:error, reason, stream_after} = TokenStream.next(stream)

      assert {:error, ^reason, ^stream_after} = TokenStream.peek(stream_after)
      # Peek should not clear the stored error
      assert stream_after.error != nil
    end

    test "strict peek/1 returns buffered tokens up until error" do
      stream = TokenStream.new("1 1 Ä", 1, 1, error_mode: :strict)
      # fetches a batch and sets error
      assert {:ok, _token, stream_after} = TokenStream.next(stream)
      # should still be able to peek one token
      assert {:ok, _token, ^stream_after} = TokenStream.peek(stream_after)

      # Peek should not clear the stored error
      assert stream_after.error != nil
    end

    test "strict peek_n/2 returns buffered tokens up until error" do
      stream = TokenStream.new("1 1 1 1 Ä", 1, 1, error_mode: :strict)
      # fetches a batch and sets error
      assert {:ok, _token, stream_after} = TokenStream.next(stream)
      # should still be able to peek one token
      assert {:ok, tokens, ^stream_after} = TokenStream.peek_n(stream_after, 3)

      assert length(tokens) == 3

      # Peek should not clear the stored error
      assert stream_after.error != nil

      # should not peek past the error
      assert {:error, _reason, tokens, ^stream_after} = TokenStream.peek_n(stream_after, 4)

      assert length(tokens) == 3
    end

    test "strict peek_n/2 reports eof and never exposes buffered tokens" do
      stream = TokenStream.new(@invalid_source, 1, 1, error_mode: :strict)
      assert {:error, reason, stream_after} = TokenStream.next(stream)

      assert {:error, ^reason, [], ^stream_after} = TokenStream.peek_n(stream_after, 3)
    end

    test "strict peek_n/2 returns EOF when requesting more tokens than available" do
      stream = TokenStream.new("1 2", 1, 1, error_mode: :strict)

      # Consume first token
      {:ok, _token, stream} = TokenStream.next(stream)

      # Peek more tokens than available (only 1 token left but asking for 5)
      assert {:eof, tokens, _stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 1
    end

    test "strict peek_n/2 encounters an error, next still returns tokens" do
      stream = TokenStream.new("1 2 Ä", 1, 1, error_mode: :strict)

      assert {:error, _, tokens, stream_after} = TokenStream.peek_n(stream, 3)
      # Should get the 2 valid tokens before error
      assert length(tokens) >= 2

      # Consume tokens until we get an error
      stream_after = consume_until_error(stream_after)
      assert stream_after.error != nil
    end

    defp consume_until_error(stream) do
      case TokenStream.next(stream) do
        {:ok, _token, new_stream} -> consume_until_error(new_stream)
        {:error, _reason, new_stream} -> new_stream
        {:eof, new_stream} -> new_stream
      end
    end

    test "strict pushback/2 cannot bypass the stored error" do
      stream = TokenStream.new("1 Ä", 1, 1, error_mode: :strict)

      # Consume the valid token before the error
      assert {:ok, token, stream_after} = TokenStream.next(stream)
      assert {:error, reason, stream_with_error} = TokenStream.next(stream_after)

      # Pushing the token back should not erase the error state
      stream_with_push = TokenStream.pushback(stream_with_error, token)

      # Should get the pushed back token first, then error
      assert {:ok, ^token, stream_after_push} = TokenStream.next(stream_with_push)
      assert {:error, ^reason, _} = TokenStream.next(stream_after_push)
      assert {:error, ^reason, _} = TokenStream.peek(stream_with_error)
    end

    test "next/1 does not refill buffer after error" do
      stream = TokenStream.new("A.\"abc\#{a}\"", 1, 1, error_mode: :strict)

      assert {:ok, {:alias, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:., _}, stream} = TokenStream.next(stream)
      assert {:ok, {:quoted_identifier_start, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:string_fragment, _, _}, stream} = TokenStream.next(stream)
      assert {:error, _, _} = TokenStream.next(stream)
    end

    test "next/1 does not refill buffer after error - error after batch boundary" do
      stream = TokenStream.new("A.\"abc\#{a}\"", 1, 1, error_mode: :strict, max_batch: 4)

      assert {:ok, {:alias, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:., _}, stream} = TokenStream.next(stream)
      assert {:ok, {:quoted_identifier_start, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:string_fragment, _, _}, stream} = TokenStream.next(stream)
      assert {:error, _, _} = TokenStream.next(stream)
    end

    test "peek/1 does not refill buffer after error" do
      stream = TokenStream.new("A.\"abc\#{a}\"", 1, 1, error_mode: :strict)

      assert {:ok, {:alias, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:., _}, stream} = TokenStream.next(stream)
      assert {:ok, {:quoted_identifier_start, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:string_fragment, _, _}, stream} = TokenStream.next(stream)
      assert {:error, _, _} = TokenStream.peek(stream)
    end

    test "peek/1 does not refill buffer after error - error after batch boundary" do
      stream = TokenStream.new("A.\"abc\#{a}\"", 1, 1, error_mode: :strict, max_batch: 4)

      assert {:ok, {:alias, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:., _}, stream} = TokenStream.next(stream)
      assert {:ok, {:quoted_identifier_start, _, _}, stream} = TokenStream.next(stream)
      assert {:ok, {:string_fragment, _, _}, stream} = TokenStream.next(stream)
      assert {:error, _, _} = TokenStream.peek(stream)
    end

    test "to_stream/1 halts on error" do
      stream = TokenStream.new("1 Ä", 1, 1, error_mode: :strict)

      tokens =
        stream
        |> TokenStream.to_stream()
        |> Enum.to_list()

      assert length(tokens) == 1
    end

    test "position/0 returns driver position on error" do
      stream = TokenStream.new("1 Ä", 1, 1, error_mode: :strict)

      {:ok, _, stream} = TokenStream.next(stream)
      {:error, _, stream} = TokenStream.next(stream)

      assert {{1, 3}, _stream} = TokenStream.position(stream)
    end

    # Phase 3: Tolerant mode recovery tests
    test "tolerant next/1 recovers from error and continues" do
      stream = TokenStream.new("1 Ä 2", 1, 1, error_mode: :tolerant)

      # First token: 1
      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token1

      # Second token: error_token (for Ä)
      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = token2

      # Third token: 2 (continues after error)
      {:ok, token3, stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token3

      # EOF
      assert {:eof, _} = TokenStream.next(stream)
    end

    test "tolerant next/1 recovers from error at EOF" do
      stream = TokenStream.new("}", 1, 1, error_mode: :tolerant)

      # First token: error_token (unexpected closer)
      {:ok, token, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = token

      # With synthesis enabled, we get synthetic { then actual }
      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:"{", _} = token2

      {:ok, token3, stream} = TokenStream.next(stream)
      assert {:"}", _} = token3

      # EOF after tokens
      assert {:eof, _} = TokenStream.next(stream)
    end

    test "tolerant peek/1 recovers error into buffer without consuming" do
      stream = TokenStream.new("Ä 1", 1, 1, error_mode: :tolerant)

      # Peek should recover error into buffer
      {:ok, token1, stream1} = TokenStream.peek(stream)
      assert {:error_token, _, _} = token1

      # Peek again should return same error token
      {:ok, token2, stream2} = TokenStream.peek(stream1)
      assert {:error_token, _, _} = token2

      # Stream unchanged
      assert stream1 == stream2

      # Next consumes the error token
      {:ok, token3, stream3} = TokenStream.next(stream2)
      assert {:error_token, _, _} = token3

      # Next token after error
      {:ok, token4, _stream4} = TokenStream.next(stream3)
      assert {:int, {{1, 3}, {1, 4}, 1}, ~c"1"} = token4
    end

    test "tolerant peek/1 after error continues" do
      stream = TokenStream.new("1 Ä 2", 1, 1, error_mode: :tolerant)

      # Consume first token
      {:ok, _, stream} = TokenStream.next(stream)

      # Peek at error
      {:ok, token, stream} = TokenStream.peek(stream)
      assert {:error_token, _, _} = token

      # Consume error
      {:ok, _, stream} = TokenStream.next(stream)

      # Peek at continuation token
      {:ok, token, _stream} = TokenStream.peek(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token
    end

    test "tolerant peek_n/2 recovers and continues filling buffer" do
      stream = TokenStream.new("1 Ä 2 3", 1, 1, error_mode: :tolerant)

      # Peek 4 tokens: 1, error, 2, 3
      {:ok, tokens, stream} = TokenStream.peek_n(stream, 4)

      assert length(tokens) == 4
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = Enum.at(tokens, 0)
      assert {:error_token, _, _} = Enum.at(tokens, 1)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = Enum.at(tokens, 2)
      assert {:int, {{1, 7}, {1, 8}, 3}, ~c"3"} = Enum.at(tokens, 3)

      # Stream unchanged
      {:ok, token, _} = TokenStream.next(stream)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token
    end

    test "tolerant peek_n/2 with multiple errors" do
      stream = TokenStream.new("Ä Ü 1", 1, 1, error_mode: :tolerant)

      # Peek 3 tokens: error, error, 1
      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 3)

      assert length(tokens) == 3
      assert {:error_token, _, _} = Enum.at(tokens, 0)
      assert {:error_token, _, _} = Enum.at(tokens, 1)
      assert {:int, {{1, 5}, {1, 6}, 1}, ~c"1"} = Enum.at(tokens, 2)
    end

    test "tolerant peek_n/2 at EOF with error" do
      stream = TokenStream.new("1 }", 1, 1, error_mode: :tolerant)

      # Peek 5 tokens: 1, error, synthetic {, actual }
      {:eof, tokens, _stream} = TokenStream.peek_n(stream, 5)

      assert length(tokens) == 4
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = Enum.at(tokens, 0)
      assert {:error_token, _, _} = Enum.at(tokens, 1)
      assert {:"{", _} = Enum.at(tokens, 2)
      assert {:"}", _} = Enum.at(tokens, 3)
    end

    test "tolerant position/1 recovers error for accurate position" do
      stream = TokenStream.new("Ä 1", 1, 1, error_mode: :tolerant)

      # Initial position
      {{line1, col1}, stream} = TokenStream.position(stream)
      assert {line1, col1} == {1, 1}

      # Consume error token
      {:ok, _, stream} = TokenStream.next(stream)

      # Position after error should be at next valid token
      {{line2, col2}, _stream} = TokenStream.position(stream)
      assert {line2, col2} == {1, 3}
    end

    test "tolerant pushback with error token works correctly" do
      stream = TokenStream.new("Ä 1", 1, 1, error_mode: :tolerant)

      # Consume error token
      {:ok, error_token, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = error_token

      # Consume next token
      {:ok, int_token, stream} = TokenStream.next(stream)
      assert {:int, {{1, 3}, {1, 4}, 1}, ~c"1"} = int_token

      # Push back both tokens
      stream =
        stream
        |> TokenStream.pushback(int_token)
        |> TokenStream.pushback(error_token)

      # Should get error token first
      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = token1

      # Then int token
      {:ok, token2, _stream} = TokenStream.next(stream)
      assert {:int, {{1, 3}, {1, 4}, 1}, ~c"1"} = token2
    end

    test "tolerant checkpoint/rewind with errors is deterministic" do
      stream = TokenStream.new("1 Ä 2", 1, 1, error_mode: :tolerant)

      # Consume first token
      {:ok, _, stream} = TokenStream.next(stream)

      # Create checkpoint before error
      {ref, stream} = TokenStream.checkpoint(stream)

      # Consume error and next token
      {:ok, error1, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = error1
      {:ok, _, stream} = TokenStream.next(stream)

      # Rewind to checkpoint
      stream = TokenStream.rewind_to(stream, ref)

      # Should get same error token again
      {:ok, error2, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = error2

      # Positions should match
      {_, {{sl1, sc1}, {el1, ec1}, _}, _} = error1
      {_, {{sl2, sc2}, {el2, ec2}, _}, _} = error2
      assert {sl1, sc1, el1, ec1} == {sl2, sc2, el2, ec2}

      # Continue should work
      {:ok, token, _} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token
    end

    test "tolerant to_stream/1 includes error tokens in output" do
      stream = TokenStream.new("1 Ä 2", 1, 1, error_mode: :tolerant)

      tokens =
        stream
        |> TokenStream.to_stream()
        |> Enum.to_list()

      assert length(tokens) == 3
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = Enum.at(tokens, 0)
      assert {:error_token, _, _} = Enum.at(tokens, 1)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = Enum.at(tokens, 2)
    end

    test "tolerant handles multiple consecutive errors" do
      stream = TokenStream.new("Ä Ü Ñ 1", 1, 1, error_mode: :tolerant)

      # Consume all tokens
      {:ok, t1, stream} = TokenStream.next(stream)
      {:ok, t2, stream} = TokenStream.next(stream)
      {:ok, t3, stream} = TokenStream.next(stream)
      {:ok, t4, stream} = TokenStream.next(stream)

      assert {:error_token, _, _} = t1
      assert {:error_token, _, _} = t2
      assert {:error_token, _, _} = t3
      assert {:int, {{1, 7}, {1, 8}, 1}, ~c"1"} = t4

      assert {:eof, _} = TokenStream.next(stream)
    end

    test "tolerant handles error in small batch size scenario" do
      stream = TokenStream.new("1 Ä 2 3", 1, 1, error_mode: :tolerant, max_batch: 2)

      # Force multiple batches with error in middle
      {:ok, _, stream} = TokenStream.next(stream)
      {:ok, error, stream} = TokenStream.next(stream)
      assert {:error_token, _, _} = error

      # Should continue across batch boundary
      {:ok, token, stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, ~c"2"} = token

      {:ok, token, _stream} = TokenStream.next(stream)
      assert {:int, {{1, 7}, {1, 8}, 3}, ~c"3"} = token
    end

    test "tolerant peek_n forces multiple recoveries during fill" do
      stream = TokenStream.new("Ä Ü 1 2", 1, 1, error_mode: :tolerant, max_batch: 1)

      # Peek 4 tokens with batch size 1 - forces multiple refills and recoveries
      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 4)

      assert length(tokens) == 4
      assert {:error_token, _, _} = Enum.at(tokens, 0)
      assert {:error_token, _, _} = Enum.at(tokens, 1)
      assert {:int, _, ~c"1"} = Enum.at(tokens, 2)
      assert {:int, _, ~c"2"} = Enum.at(tokens, 3)
    end
  end

  describe "Batching" do
    # Helper to consume up to n tokens using next/1
    defp consume_n(stream, n, acc \\ 0) do
      cond do
        acc >= n ->
          {acc, stream}

        true ->
          case TokenStream.next(stream) do
            {:ok, _token, stream} -> consume_n(stream, n, acc + 1)
            {:eof, stream} -> {acc, stream}
          end
      end
    end

    # Helper to consume all tokens until EOF
    defp consume_all(stream, acc \\ 0) do
      case TokenStream.next(stream) do
        {:ok, _token, stream} -> consume_all(stream, acc + 1)
        {:eof, stream} -> {acc, stream}
      end
    end

    test "iterates large file with small batches and successive peeks" do
      # Use a large, real-world Elixir source file
      path = Enum.module_info()[:compile][:source] |> to_string()
      content = File.read!(path)

      stream = TokenStream.new(content, 1, 1, max_batch: 3)

      # Repeatedly peek increasing amounts, then consume one token
      # to force multiple refills under a small batch cap
      {_, stream} =
        Enum.reduce(1..50, {0, stream}, fn k, {count, s} ->
          case TokenStream.peek_n(s, k) do
            {result, tokens, s2} when result in [:ok, :eof] ->
              assert length(tokens) >= 1
              {:ok, _t, s3} = TokenStream.next(s2)
              {count + 1, s3}
          end
        end)

      # Then consume more tokens to ensure continued progress
      {taken, stream} = consume_n(stream, 150)
      assert taken == 150

      # Peeking a large demand should still return some tokens (not EOF yet)
      case TokenStream.peek_n(stream, 100) do
        {:ok, tokens, _} -> assert length(tokens) > 0
      end
    end

    test "peek_n returns EOF only after full consumption" do
      path = Enum.module_info()[:compile][:source] |> to_string()
      content = File.read!(path)
      stream = TokenStream.new(content, 1, 1, max_batch: 4)

      # Consume all tokens
      {_total, stream} = consume_all(stream)

      # Now peeking for any positive N should yield EOF
      assert {:eof, [], _} = TokenStream.peek_n(stream, 1)
      assert {:eof, [], _} = TokenStream.peek_n(stream, 10)
    end

    test "max_batch does not affect produced tokens" do
      path = Enum.module_info()[:compile][:source] |> to_string()
      content = File.read!(path)

      # tokenize with big batch size
      stream = TokenStream.new(content, 1, 1, max_batch: 256_000)

      # Consume all tokens
      {big_batch_total, _stream} = consume_all(stream)

      for max_batch <- [
            # 1, 2, 3, 5, 10, 100, 1000,
            10000,
            20613
          ] do
        # tokenize with small batch size
        stream = TokenStream.new(content, 1, 1, max_batch: max_batch)

        # Consume all tokens
        {total, _stream} = consume_all(stream)

        assert big_batch_total == total
      end
    end
  end

  describe "peek near EOF" do
    test "peek_n returns available tokens then EOF once consumed" do
      stream = TokenStream.new("1 +", 1, 1)

      # Demand more than available; should get fewer, signal EOF
      {:eof, tokens, stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 2

      # Consume both tokens
      {:ok, _t1, stream} = TokenStream.next(stream)
      {:ok, _t2, stream} = TokenStream.next(stream)

      # Now peeking any N should return EOF
      assert {:eof, [], _} = TokenStream.peek_n(stream, 5)
    end

    test "peek_n on empty input returns EOF" do
      stream = TokenStream.new("")
      assert {:eof, [], _} = TokenStream.peek_n(stream, 3)
    end
  end
end
