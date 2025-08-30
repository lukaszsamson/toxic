defmodule Toxic.Scope do
  require Record

  Record.defrecord(
    :scope,
    :toxic_tokenizer,
    Record.extract(:toxic_tokenizer, from: "src/toxic.hrl")
  )

  def track_ascii(true, scope), do: scope
  def track_ascii(false, scope), do: scope(scope, ascii_identifiers_only: false)
end
