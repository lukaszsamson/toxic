defmodule Toxic.Scope do
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
    # TODO: do we need that?
    identifier_tokenizer: Toxic.IdentifierTokenizer,
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
            identifier_tokenizer: module(),
            ascii_identifiers_only: boolean(),
            indentation: non_neg_integer(),
            column: pos_integer(),
            mismatch_hints: list(),
            warnings: list(),
            elixir_compatibility: boolean()
          )

  def track_ascii(true, scope), do: scope
  def track_ascii(false, scope), do: scope(scope, ascii_identifiers_only: false)

  @doc """
  Prepends a warning to the scope's warning list.
  Warnings are stored as `{{line, column}, message}` tuples.
  """
  def prepend_warning(line, column, message, scope) do
    warnings = scope(scope, :warnings)
    scope(scope, warnings: [{{line, column}, message} | warnings])
  end
end
