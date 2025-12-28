defmodule Toxic.Driver.Deferrals do
  @moduledoc false

  @spec flush(list(), list()) :: list()
  def flush(output, deferrals) do
    output ++ Enum.reverse(deferrals)
  end

  @spec append(list(), list(), list()) :: list()
  def append(output, deferrals, tokens) do
    output ++ Enum.reverse(deferrals, tokens)
  end
end
