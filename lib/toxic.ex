defmodule Toxic do
  @moduledoc """
  Documentation for `Toxic`.
  """

  defdelegate tokenize(text), to: :toxic_tokenizer

  defdelegate tokenize(text, line, column, opts), to: :toxic_tokenizer

  defdelegate tokenize(text, line, opts), to: :toxic_tokenizer
end
