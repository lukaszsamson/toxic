defmodule Toxic.RewindReproTest do
  use ExUnit.Case

  defp drain_to_eof(stream) do
    case Toxic.next(stream) do
      {:ok, _tok, s} -> drain_to_eof(s)
      {:eof, s} -> s
      {:error, _err, s} -> s
    end
  end

  @tag :rewind_repro
  test "rewind_to/2 restores logical token position even after refills" do
    # The key property: `checkpoint/1` must capture *all* stream state needed to resume tokenization
    # from the same logical point. If it doesn't, rewinding can cause the next refill to tokenize
    # from the wrong remaining input, which often manifests as a spurious terminator error.

    stream = Toxic.new("1 + 2 * 3", 1, 1, max_batch: 1, error_mode: :tolerant)

    # Create a checkpoint at the very beginning, before any buffering/refill happens.
    {ref, stream} = Toxic.checkpoint(stream)

    # Advance the stream all the way to EOF, forcing multiple refills and mutating
    # the internal remaining input (`stream.source`).
    stream = drain_to_eof(stream)

    # Rewind to the checkpoint; the next token should be the opening paren again.
    stream = Toxic.rewind_to(stream, ref)

    assert {:ok, {:int, _meta, _value}, _stream} = Toxic.next(stream)
  end
end
