defmodule Toxic.Driver.Deferrals do
  @moduledoc false

  # A3 optimization: Specialize flush/2 and append/3 to avoid unnecessary
  # list operations when one of the inputs is empty.
  # Use :lists.reverse/1,2 instead of Enum.reverse/1,2 in hot paths.

  @compile {:inline, flush: 2, append: 3}

  @spec flush(list(), list()) :: list()
  # When output is empty, just reverse deferrals - no concatenation needed
  def flush([], deferrals), do: :lists.reverse(deferrals)
  # When deferrals is empty, just return output - no reverse needed
  def flush(output, []), do: output
  # General case: concatenate output with reversed deferrals
  def flush(output, deferrals), do: output ++ :lists.reverse(deferrals)

  @spec append(list(), list(), list()) :: list()
  # When output is empty, reverse deferrals onto tokens directly
  def append([], deferrals, tokens), do: :lists.reverse(deferrals, tokens)
  # When deferrals is empty, just concatenate output with tokens
  def append(output, [], tokens), do: output ++ tokens
  # General case: concatenate output with reversed deferrals and tokens
  def append(output, deferrals, tokens), do: output ++ :lists.reverse(deferrals, tokens)
end
