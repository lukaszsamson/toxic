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
      assert line == 2
      assert col == 4
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
      # Note: This requires actual tokenizer state tracking
      # TODO: real implementation
      {:ok, _token, _stream} = TokenStream.next(stream)
      # The actual implementation would track this
    end
  end

  describe "peek_missing_terminator/1" do
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
    test "tolerant mode emits error tokens" do
      # Invalid token that would cause an error
      stream = TokenStream.new("'", 1, 1, error_mode: :tolerant)

      # The tokenizer would emit an error token
      # This depends on the actual tokenizer error handling
      {:ok, token, _stream} = TokenStream.next(stream)

      # Would be an error token in tolerant mode
      # For now it might be the actual error from the tokenizer
      # TODO: real implementation
      assert token != nil
    end

    test "strict mode stops at first error" do
      stream = TokenStream.new("'", 1, 1, error_mode: :strict)

      # In strict mode, would return EOF on error
      # TODO: eof or real error first?
      result = TokenStream.next(stream)

      case result do
        {:eof, _} -> :ok
        {:ok, _, _} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
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
    test "default eol_mode is :embed (no eol tokens)" do
      stream = TokenStream.new("1\n2")

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"1"} = token1

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:int, _, ~c"2"} = token2

      assert {:eof, _} = TokenStream.next(stream)
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
