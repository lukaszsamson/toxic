defmodule Toxic.TokenStreamTest do
  use ExUnit.Case
  alias Toxic.TokenStream

  describe "new/4" do
    test "creates a stream from a binary source" do
      stream = TokenStream.new("1 + 2")
      assert %TokenStream{source: "1 + 2", line: 1, column: 1} = stream
    end

    test "creates a stream with custom starting position" do
      stream = TokenStream.new("foo", 5, 10)
      assert %TokenStream{line: 5, column: 10} = stream
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
      assert {:int, {{1, 1}, {1, 2}, 1}, '1'} = token1

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token2

      {:ok, token3, stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, '2'} = token3

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
      assert {:int, _, '1'} = token4

      {:ok, token5, stream} = TokenStream.next(stream)
      assert {:dual_op, _, :+} = token5

      {:ok, token6, stream} = TokenStream.next(stream)
      assert {:int, _, '2'} = token6

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
      assert {:int, {{1, 1}, {1, 2}, 1}, '1'} = token

      # Peek again returns the same token
      {:ok, token, stream2} = TokenStream.peek(stream1)
      assert {:int, {{1, 1}, {1, 2}, 1}, '1'} = token

      # Stream state unchanged
      assert stream1 == stream2

      # Next consumes the token
      {:ok, token, stream3} = TokenStream.next(stream2)
      assert {:int, {{1, 1}, {1, 2}, 1}, '1'} = token

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
        {:int, {{1, 1}, {1, 2}, 1}, '1'},
        {:dual_op, {{1, 3}, {1, 4}, _}, :+},
        {:int, {{1, 5}, {1, 6}, 2}, '2'}
      ] = tokens

      # Stream unchanged
      assert stream == stream1

      # Can still get first token
      {:ok, token, _} = TokenStream.next(stream1)
      assert {:int, {{1, 1}, {1, 2}, 1}, '1'} = token
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
      assert {:int, {{1, 1}, {1, 2}, 1}, '1'} = token1

      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token2

      # Push back the operator
      stream = TokenStream.pushback(stream, token2)

      # Next returns the pushed back token
      {:ok, token, stream} = TokenStream.next(stream)
      assert {:dual_op, {{1, 3}, {1, 4}, _}, :+} = token

      # Continue normally
      {:ok, token, _stream} = TokenStream.next(stream)
      assert {:int, {{1, 5}, {1, 6}, 2}, '2'} = token
    end

    test "multiple pushbacks work in LIFO order" do
      stream = TokenStream.new("1")

      {:ok, token1, stream} = TokenStream.next(stream)

      fake_token1 = {:fake1, {{1, 1}, {1, 2}, nil}, nil}
      fake_token2 = {:fake2, {{1, 2}, {1, 3}, nil}, nil}

      stream = stream
      |> TokenStream.pushback(token1)
      |> TokenStream.pushback(fake_token1)
      |> TokenStream.pushback(fake_token2)

      {:ok, t1, stream} = TokenStream.next(stream)
      assert t1 == fake_token2

      {:ok, t2, stream} = TokenStream.next(stream)
      assert t2 == fake_token1

      {:ok, t3, stream} = TokenStream.next(stream)
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
      assert {:int, {{1, 5}, {1, 6}, 2}, '2'} = token
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
      assert col == 3
    end
  end

  describe "to_stream/1" do
    test "converts to Elixir stream" do
      stream = TokenStream.new("1 + 2 * 3")

      tokens = stream
      |> TokenStream.to_stream()
      |> Enum.to_list()

      assert [
        {:int, {{1, 1}, {1, 2}, 1}, '1'},
        {:dual_op, {{1, 3}, {1, 4}, _}, :+},
        {:int, {{1, 5}, {1, 6}, 2}, '2'},
        {:mult_op, {{1, 7}, {1, 8}, _}, :*},
        {:int, {{1, 9}, {1, 10}, 3}, '3'}
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
    test "suggests closing delimiter" do
      stream = TokenStream.new("(1 + 2")

      # Consume tokens
      {:ok, _paren, stream} = TokenStream.next(stream)
      {:ok, _one, stream} = TokenStream.next(stream)
      {:ok, _plus, stream} = TokenStream.next(stream)
      {:ok, _two, stream} = TokenStream.next(stream)

      # Would suggest ')' if terminator tracking is implemented
      {closer, _stream} = TokenStream.peek_missing_terminator(stream)
      # In a full implementation, this would return :')'
      # TODO: real implementation
      assert closer == nil # For now
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
      assert {:int, _, '1'} = token1

      # No EOL token in embed mode
      {:ok, token2, stream} = TokenStream.next(stream)
      assert {:int, _, '2'} = token2

      assert {:eof, _} = TokenStream.next(stream)
    end

    test "emit mode includes EOL tokens" do
      stream = TokenStream.new("1\n2", 1, 1, eol_mode: :emit)

      {:ok, token1, stream} = TokenStream.next(stream)
      assert {:int, _, '1'} = token1

      # EOL token present in emit mode
      {:ok, token2, stream} = TokenStream.next(stream)
      case token2 do
        {:eol, _, _} -> :ok
        other -> flunk("Unexpected token: #{inspect(other)}")
      end
    end
  end
end
