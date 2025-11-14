defmodule Toxic.Scope do
  @moduledoc """
  Tokenizer scope and configuration record.

  The Scope record manages tokenizer configuration and state during lexical analysis:
  - **Terminators**: Stack of opening/closing delimiters being tracked
  - **Unescaping**: Whether to process escape sequences in strings
  - **Identifier rules**: ASCII-only or Unicode identifier support
  - **Comments and warnings**: Comment preservation and warning collection
  - **Compatibility mode**: Elixir reference tokenizer compatibility

  This is an Erlang record (managed via `Record.defrecord/2`) that is passed
  through the tokenization pipeline and updated as scopes are entered/exited
  and configuration changes.
  """

  require Record

  Record.defrecord(
    :scope,
    :toxic_tokenizer,
    terminators: [],
    unescape: true,
    cursor_completion: false,
    existing_atoms_only: false,
    static_atoms_encoder: nil,
    preserve_comments: nil,
    ascii_identifiers_only: true,
    indentation: 0,
    column: 1,
    mismatch_hints: [],
    warnings: [],
    elixir_compatibility: false
  )

  @type terminator_entry :: {atom(), any(), non_neg_integer()}
  @type preserve_comments_fun ::
          (integer(), integer(), list(), list(), list() -> any())

  @type scope ::
          record(
            :scope,
            terminators: :none | [terminator_entry()],
            unescape: boolean(),
            cursor_completion: boolean(),
            existing_atoms_only: boolean(),
            static_atoms_encoder: nil | function(),
            preserve_comments: nil | false | preserve_comments_fun(),
            ascii_identifiers_only: boolean(),
            indentation: non_neg_integer(),
            column: pos_integer(),
            mismatch_hints: list(),
            warnings: [Toxic.Warning.t()],
            elixir_compatibility: boolean()
          )

  def track_ascii(true, scope), do: scope
  def track_ascii(false, scope), do: scope(scope, ascii_identifiers_only: false)

  @doc """
  Prepends a structured warning to the scope's warning list.

  Takes a `%Toxic.Warning{}` struct and adds it to the front of the warnings list.
  This is the preferred way to add warnings.

  ## Example

      warning = Toxic.Warning.deprecated_single_quote_atom(1, 5)
      scope = Toxic.Scope.prepend_warning(warning, scope)
  """
  def prepend_warning(%Toxic.Warning{} = warning, scope) do
    warnings = scope(scope, :warnings)
    scope(scope, warnings: [warning | warnings])
  end
end
