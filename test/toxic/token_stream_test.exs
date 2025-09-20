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
      stream = TokenStream.new("foo", 1, 1, eol_mode: :emit, max_batch: 10)
      assert stream.opts[:eol_mode] == :emit
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

      # Stream unchanged
      assert stream == stream1

      # Can still get first token
      {:ok, token, _} = TokenStream.next(stream1)
      assert {:int, {{1, 1}, {1, 2}, 1}, ~c"1"} = token
    end

    test "returns fewer tokens at EOF" do
      stream = TokenStream.new("1 +")

      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 5)
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

      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 6)
      assert length(tokens) == 5

      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 2)

      # This will fetch 3 times
      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 5

      stream = TokenStream.new("1 + 2 * 3", 1, 1, max_batch: 5)

      # This will fetch 1 time
      {:ok, tokens, stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 5

      {:ok, tokens, _stream} = TokenStream.peek_n(stream, 6)
      assert length(tokens) == 5
    end

    test "returns empty list for n <= 0" do
      stream = TokenStream.new("1 + 2")
      {:ok, tokens, _} = TokenStream.peek_n(stream, 0)
      assert tokens == []
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

      {:ok, [^fake_token2, ^fake_token1], _stream} = TokenStream.peek_n(stream, 3)
    end

    test "peek_n at eof, buffered token" do
      stream = TokenStream.new("1")

      {:ok, token, stream} = TokenStream.peek(stream)

      {:ok, [^token], _stream} = TokenStream.peek_n(stream, 3)
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

    # TODO: the tests here return terminators after a batch instead of on current token
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
      assert {:ok, tokens, ^stream_after} = TokenStream.peek_n(stream_after, 4)

      assert length(tokens) == 3
    end

    test "strict peek_n/2 reports eof and never exposes buffered tokens" do
      stream = TokenStream.new(@invalid_source, 1, 1, error_mode: :strict)
      assert {:error, _reason, stream_after} = TokenStream.next(stream)

      assert {:ok, [], ^stream_after} = TokenStream.peek_n(stream_after, 3)
    end

    test "strict peek_n/2 encounters an error, next still returns tokens" do
      stream = TokenStream.new("1 2 Ä", 1, 1, error_mode: :strict)

      assert {:ok, tokens, stream_after} = TokenStream.peek_n(stream, 3)
      # Should get at least the 2 valid tokens before error
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
  end

  describe "EOL handling" do
    # TODO: tests on operators, ;, dual_op, comment blocks
    test "embed mode filters EOL tokens" do
      stream = TokenStream.new("1\n2", 1, 1, eol_mode: :embed)

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = token1

      # No EOL token in embed mode
      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"2"} = token2

      assert {:eof, _} = TokenStream.next(stream)
    end

    test "embed mode filters EOL tokens in peek" do
      stream = TokenStream.new("1\n2", 1, 1, eol_mode: :embed)

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = token1

      # No EOL token in embed mode
      {:ok, token2, stream} = TokenStream.peek(stream)
      assert {:int, _, ~c"2"} = token2

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"2"} = token2

      assert {:eof, _} = TokenStream.next(stream)
    end

    test "emit mode includes EOL tokens" do
      stream = TokenStream.new("1\n2", 1, 1, eol_mode: :emit)

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = token1

      # EOL token present in emit mode
      {:ok, token2, _stream} = TokenStream.next(stream)

      case token2 do
        {:eol, _} -> :ok
        other -> flunk("Unexpected token: #{inspect(other)}")
      end
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

      stream = TokenStream.new(content, 1, 1, max_batch: 3, eol_mode: :embed)

      # Repeatedly peek increasing amounts, then consume one token
      # to force multiple refills under a small batch cap
      {_, stream} =
        Enum.reduce(1..50, {0, stream}, fn k, {count, s} ->
          case TokenStream.peek_n(s, k) do
            {:ok, tokens, s2} ->
              assert length(tokens) >= 1
              {:ok, _t, s3} = TokenStream.next(s2)
              {count + 1, s3}

            {:eof, _} ->
              flunk("Unexpected EOF while peeking with k=#{k} at count=#{count}")
          end
        end)

      # Then consume more tokens to ensure continued progress
      {taken, stream} = consume_n(stream, 150)
      assert taken == 150

      # Peeking a large demand should still return some tokens (not EOF yet)
      case TokenStream.peek_n(stream, 100) do
        {:ok, tokens, _} -> assert length(tokens) > 0
        {:eof, _} -> flunk("Unexpected EOF after partial consumption")
      end
    end

    test "peek_n returns EOF only after full consumption" do
      path = Enum.module_info()[:compile][:source] |> to_string()
      content = File.read!(path)
      stream = TokenStream.new(content, 1, 1, max_batch: 4, eol_mode: :embed)

      # Consume all tokens
      {_total, stream} = consume_all(stream)

      # Now peeking for any positive N should yield EOF
      assert {:eof, _} = TokenStream.peek_n(stream, 1)
      assert {:eof, _} = TokenStream.peek_n(stream, 10)
    end

    test "max_batch does not affect produced tokens" do
      path = Enum.module_info()[:compile][:source] |> to_string()
      content = File.read!(path)

      # tokenize with big batch size
      stream = TokenStream.new(content, 1, 1, max_batch: 256_000, eol_mode: :embed)

      # Consume all tokens
      {big_batch_total, _stream} = consume_all(stream)

      for max_batch <- [
            # 1, 2, 3, 5, 10, 100, 1000,
            10000,
            20613
          ] do
        # tokenize with small batch size
        stream = TokenStream.new(content, 1, 1, max_batch: max_batch, eol_mode: :embed)

        # Consume all tokens
        {total, _stream} = consume_all(stream)

        assert big_batch_total == total
      end
    end
  end

  describe "peek near EOF" do
    test "peek_n returns available tokens then EOF once consumed" do
      stream = TokenStream.new("1 +", 1, 1, eol_mode: :embed)

      # Demand more than available; should get fewer, not EOF
      {:ok, tokens, stream} = TokenStream.peek_n(stream, 5)
      assert length(tokens) == 2

      # Consume both tokens
      {:ok, _t1, stream} = TokenStream.next(stream)
      {:ok, _t2, stream} = TokenStream.next(stream)

      # Now peeking any N should return EOF
      assert {:eof, _} = TokenStream.peek_n(stream, 5)
    end

    test "peek_n on empty input returns EOF" do
      stream = TokenStream.new("")
      assert {:eof, _} = TokenStream.peek_n(stream, 3)
    end
  end

  describe "defaults" do
    test "default eol_mode is :emit" do
      stream = TokenStream.new("1\n2")

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = token1

      {:ok, token2, _stream} = TokenStream.next(stream)
      assert {:eol, _} = token2
    end
  end

  describe "peek_n/2 with EOL filtering" do
    test "returns fewer tokens when intermediate EOLs are filtered" do
      stream = TokenStream.new("1\n\n2", 1, 1, eol_mode: :embed)

      {:ok, tokens, stream1} = TokenStream.peek_n(stream, 3)

      assert [
               {:int, _, ~c"1"},
               {:int, _, ~c"2"}
             ] = tokens

      # Stream remains unchanged after peek
      assert stream == stream1

      # Ensure normal consumption still works
      {:ok, t1, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = t1
      {:ok, t2, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"2"} = t2
      assert {:eof, _} = TokenStream.next(stream)
    end
  end
end
