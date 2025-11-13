defmodule ToxicScopeStateTest do
  @moduledoc """
  Tests that verify terminator stack state after error recovery.
  Ensures that the scope stack remains consistent and properly balanced
  even when errors occur during parsing.
  """
  use ExUnit.Case

  # -- Helper Functions -------------------------------------------------------

  defp get_final_stream(input, opts \\ []) do
    default_opts = [error_mode: :tolerant, synthesis: true]
    merged_opts = Keyword.merge(default_opts, opts)

    stream = Toxic.new(input, 1, 1, merged_opts)
    drain_stream(stream)
  end

  defp drain_stream(stream) do
    case Toxic.next(stream) do
      {:ok, _token, new_stream} -> drain_stream(new_stream)
      {:eof, final_stream} -> final_stream
      {:error, _reason, final_stream} -> final_stream
    end
  end

  defp count_open_terminators(stream) do
    {terminators, _stream} = Toxic.current_terminators(stream)
    length(terminators)
  end

  # -- Single Error Recovery Tests --------------------------------------------

  describe "scope state after single error recovery" do
    test "stack empty after unexpected closer" do
      final = get_final_stream(")")
      assert count_open_terminators(final) == 0
    end

    test "stack empty after mismatched closer" do
      final = get_final_stream("([)")
      assert count_open_terminators(final) == 0
    end

    test "stack correct after partial nesting with mismatch" do
      final = get_final_stream("( [ ) ]")
      # Both should be closed despite mismatch
      assert count_open_terminators(final) == 0
    end

    test "stack empty after missing closer at EOF" do
      final = get_final_stream("(")
      # Should be synthesized and closed
      assert count_open_terminators(final) == 0
    end
  end

  # -- Nested Error Recovery Tests --------------------------------------------

  describe "scope state after nested errors" do
    test "stack depth correct after nested missing closers" do
      final = get_final_stream("foo([{")
      # All three should be synthesized and closed at EOF
      assert count_open_terminators(final) == 0
    end

    test "stack correct after error then valid code" do
      final = get_final_stream("([) + (foo)")
      # After mismatch recovery, new ( should open and close normally
      assert count_open_terminators(final) == 0
    end

    test "triple nested mismatch closes all scopes" do
      final = get_final_stream("([{)")
      # All openers should be closed despite mismatches
      assert count_open_terminators(final) == 0
    end

    test "alternating valid and error scopes" do
      final = get_final_stream("(foo) [bar ( baz ]")
      # First pair valid, second has mismatch, should all be closed
      assert count_open_terminators(final) == 0
    end
  end

  # -- Continuation After Recovery Tests --------------------------------------

  describe "scope state during continuation after recovery" do
    test "new scope opens and closes correctly after unexpected closer" do
      # After an unexpected closer error, new scopes should work normally
      final = get_final_stream(") (foo)")
      # The unexpected closer error is recovered, new () pair should be balanced
      assert count_open_terminators(final) == 0
    end

    test "deep nesting works after recovery" do
      final = get_final_stream("([) ( [ { } ] )")
      # After initial mismatch, subsequent nesting should work normally
      assert count_open_terminators(final) == 0
    end

    test "multiple errors with interspersed valid code" do
      final = get_final_stream(") (a) ] [b] } {c}")
      # Multiple unexpected closers, but valid pairs should still balance
      assert count_open_terminators(final) == 0
    end
  end
end
