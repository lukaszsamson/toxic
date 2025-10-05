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

  @doc """
  Legacy warning function for backward compatibility during migration.

  This function creates an unstructured warning with a generic `:legacy_unstructured` code.
  **This will be removed after migration is complete.**

  Use `prepend_warning/2` with a structured `Toxic.Warning` instead.

  ## Example

      # Old way (deprecated)
      scope = Toxic.Scope.prepend_warning_legacy(1, 5, ~c"some warning", scope)

      # New way (preferred)
      warning = Toxic.Warning.deprecated_single_quote_atom(1, 5)
      scope = Toxic.Scope.prepend_warning(warning, scope)
  """
  def prepend_warning_legacy(line, column, message, scope) do
    warning = %Toxic.Warning{
      code: :legacy_unstructured,
      domain: :general,
      token_display: message,
      details: %{line: line, column: column, message: message}
    }

    prepend_warning(warning, scope)
  end

  @doc """
  **DEPRECATED:** Use `prepend_warning/2` with structured warnings instead.

  This is maintained temporarily for backward compatibility.
  """
  def prepend_warning(line, column, message, scope)
      when is_integer(line) and is_integer(column) do
    prepend_warning_legacy(line, column, message, scope)
  end
end
