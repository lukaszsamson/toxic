defmodule Toxic.Error do
  @moduledoc """
  Structured error for Toxic, used in both strict and tolerant modes.

  This module serves as the single source of truth for:
  - Error codes and their domains
  - Details contracts used for message formatting and tolerant recovery
  - Legacy compatibility with Elixir-style reason tuples
  """

  @typedoc "High-level grouping for error codes"
  @type domain ::
          :terminator
          | :interpolation
          | :string
          | :heredoc
          | :sigil
          | :identifier
          | :keyword
          | :map
          | :number
          | :alias
          | :reserved
          | :encoding
          | :comment
          | :vc
          | :general

  @typedoc "Severity level"
  @type severity :: :error | :warning

  @typedoc "Canonical machine-readable error codes"
  @type code ::
          # Terminators
          :terminator_unexpected_closer
          | :terminator_mismatched_closer
          | :terminator_missing_closer
          | :reserved_unexpected_end
          # Interpolation/String/Sigil/Heredoc
          | :interpolation_missing_terminator
          | :interpolation_not_allowed_in_quoted_identifier
          | :string_missing_terminator
          | :heredoc_missing_terminator
          | :heredoc_invalid_header
          | :sigil_invalid_name
          | :sigil_invalid_delimiter
          # Map & Keyword
          | :map_unexpected_space_after_percent
          | :map_invalid_open_delimiter
          | :keyword_missing_space_after_colon
          | :keyword_do_with_fn_invalid
          # Identifier/Alias/Reserved
          | :identifier_empty
          | :identifier_mixed_script
          | :identifier_confusable
          | :identifier_nfkc_needed
          | :identifier_unexpected_token
          | :identifier_invalid_char
          | :identifier_atom_length_limit
          | :identifier_nonexistent_atom_when_existing_only
          | :alias_invalid_character
          | :alias_unexpected_paren
          | :reserved_token_used
          # Number
          | :number_trailing_garbage
          | :number_invalid_float
          # Encoding/Comment/VC
          | :encoding_invalid
          | :comment_invalid_bidi
          | :comment_invalid_linebreak
          | :vc_merge_conflict_marker
          # General fallback
          | :unexpected_token
          | :syntax_error

  @typedoc "Start and end positions for a range (inclusive start, exclusive end)"
  @type position :: {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}}

  @typedoc "Structured error record"
  @type t :: %__MODULE__{
          code: code(),
          domain: domain(),
          severity: severity(),
          # Span of the immediate error trigger (e.g., the unexpected closer).
          # May be nil for contextual errors whose positions are carried via details
          # (e.g., missing terminator at EOF uses start_line/start_column).
          position: position() | nil,
          # Minimal display for the token that triggered the error (e.g. ")", "%(")
          token_display: charlist() | nil,
          # Free-form context used by message formatting and recovery.
          # See per-code details contracts below.
          details: map()
        }

  @enforce_keys [:code]
  defstruct code: nil,
            domain: :general,
            severity: :error,
            position: nil,
            token_display: nil,
            details: %{}

  @doc """
  Format a user-facing message for the given error, matching Elixir-style wording.

  Returns iodata.
  """
  @spec format(t()) :: iodata()
  def format(%__MODULE__{code: :terminator_mismatched_closer, token_display: tok}) do
    [~c"unexpected token: ", List.wrap(tok)]
  end

  def format(%__MODULE__{code: :terminator_missing_closer, details: details}) do
    expected = Map.fetch!(details, :expected_delimiter)
    chars = terminator_chars(expected)
    :io_lib.format(~c"missing terminator: ~ts", [chars])
  end

  def format(%__MODULE__{code: :string_missing_terminator, details: details}) do
    expected = Map.get(details, :expected_delimiter, Map.get(details, :opening_delimiter))
    chars = terminator_chars(expected)
    msg = :io_lib.format(~c"missing terminator: ~ts", [chars])
    suffix = Map.get(details, :suffix_iolist, [])
    [msg, suffix]
  end

  def format(%__MODULE__{code: :heredoc_missing_terminator, details: details}) do
    expected = Map.get(details, :expected_delimiter, Map.get(details, :opening_delimiter))
    chars = terminator_chars(expected)
    msg = :io_lib.format(~c"missing terminator: ~ts", [chars])
    suffix = Map.get(details, :suffix_iolist, [])
    [msg, suffix]
  end

  def format(%__MODULE__{code: :interpolation_missing_terminator}) do
    :io_lib.format(~c"missing interpolation terminator: \"~ts\"", [[?}]] )
  end

  def format(%__MODULE__{code: :keyword_missing_space_after_colon}) do
    ~c"keyword argument must be followed by space after:"
  end

  def format(%__MODULE__{code: :map_invalid_open_delimiter}) do
    ~c"expected %{ to define a map, got: "
  end

  def format(%__MODULE__{code: :map_unexpected_space_after_percent}) do
    [
      ~c"unexpected space between % and {\n\n",
      ~c"If you want to define a map, write %{...}, with no spaces.\n",
      ~c"If you want to define a struct, write %StructName{...}.\n\n",
      ~c"Syntax error before: "
    ]
  end

  def format(%__MODULE__{code: :reserved_unexpected_end}) do
    ~c"unexpected reserved word: end"
  end

  def format(%__MODULE__{code: :heredoc_invalid_header, details: %{delim: delim}}) do
    # Align with phrasing used in Elixir tokenizer
    [
      ~c"heredoc allows only whitespace characters followed by a new line after opening ",
      List.wrap(delim)
    ]
  end

  def format(%__MODULE__{code: :alias_unexpected_paren}) do
    ~c"unexpected ( after alias"
  end

  def format(%__MODULE__{code: :number_trailing_garbage, details: d}) do
    # Use prebuilt message captured at error site; fallback to generic
    Map.get(d, :msg_iolist, ~c"invalid character after number")
  end

  def format(%__MODULE__{code: :number_invalid_float}) do
    ~c"invalid float number"
  end

  def format(%__MODULE__{code: :sigil_invalid_name}) do
    ~c"invalid sigil name, it should be either a one-letter lowercase letter or an uppercase letter optionally followed by uppercase letters and digits, got: "
  end

  def format(%__MODULE__{code: :sigil_invalid_delimiter}) do
    ~c"invalid sigil delimiter: "
  end

  def format(%__MODULE__{code: :comment_invalid_bidi}) do
    ~c"invalid bidirectional formatting character in comment: "
  end

  def format(%__MODULE__{code: :comment_invalid_linebreak}) do
    ~c"invalid line break character in comment: "
  end

  def format(%__MODULE__{code: :vc_merge_conflict_marker}) do
    ~c"found an unexpected version control marker, please resolve the conflicts: "
  end

  def format(%__MODULE__{code: :identifier_invalid_char, details: d}) do
    Map.get(d, :msg_iolist, ~c"invalid character in identifier: ")
  end

  def format(%__MODULE__{code: :reserved_token_used}) do
    ~c"reserved token: "
  end

  def format(%__MODULE__{code: :keyword_do_with_fn_invalid, details: d}) do
    # Message uses tuple {prefix, help}
    {~c"unexpected reserved word: ", Map.get(d, :help_iolist, [])}
  end

  def format(%__MODULE__{code: :unexpected_token, token_display: tok}) do
    [~c"unexpected token: ", List.wrap(tok)]
  end

  def format(%__MODULE__{}) do
    ~c"syntax error"
  end

  @doc """
  Convert a structured error to a legacy reason tuple `{meta_kv, message_iodata, token_chars}`
  used by strict mode and strict-mode tests.
  """
  @spec to_reason_tuple(t()) :: {keyword(), iodata(), iodata() | []}
  def to_reason_tuple(%__MODULE__{} = error) do
    validate_details!(error)
    meta_kv = meta_from(error)

    message =
      case error.code do
        :keyword_do_with_fn_invalid -> format(error)
        :reserved_unexpected_end -> {~c"unexpected reserved word: ", Map.get(error.details, :suffix_iolist, [])}
        _ -> format(error)
      end

    # Decide whether to place separator/token in `token_chars` per legacy conventions
    token_chars =
      case error.code do
        :terminator_mismatched_closer -> List.wrap(error.token_display)
        :heredoc_invalid_header -> List.wrap(error.token_display)
        :sigil_invalid_name -> List.wrap(error.token_display)
        :sigil_invalid_delimiter -> List.wrap(error.token_display)
        :map_invalid_open_delimiter -> List.wrap(error.token_display)
        :map_unexpected_space_after_percent -> List.wrap(error.token_display)
        :number_trailing_garbage -> List.wrap(error.token_display)
        :number_invalid_float -> List.wrap(error.token_display)
        :identifier_invalid_char -> List.wrap(error.token_display)
        :reserved_token_used -> List.wrap(error.token_display)
        :vc_merge_conflict_marker -> List.wrap(error.token_display)
        :unexpected_token -> List.wrap(error.token_display)
        _ -> []
      end

    {meta_kv, message, token_chars}
  end

  @doc """
  Convert legacy error shapes into a structured `%Toxic.Error{}`.

  Supported inputs:
  - `%Toxic.Error{}` – returned as-is
  - `{meta_kv :: keyword(), message :: iodata(), token_chars :: iodata() | []}` –
    converted with best-effort code inference using `meta_kv` keys and message prefix
  - `atom()` – mapped to generic codes when possible; otherwise :syntax_error

  Unknown shapes fall back to `%Toxic.Error{code: :syntax_error, details: %{legacy: term}}`.
  """
  @spec ensure_struct(term()) :: t()
  def ensure_struct(%__MODULE__{} = err), do: err

  def ensure_struct({meta_kv, message, token_chars}) when is_list(meta_kv) do
    code =
      cond do
        Keyword.get(meta_kv, :error_type) == :mismatched_delimiter ->
          :terminator_mismatched_closer

        Keyword.has_key?(meta_kv, :opening_delimiter) and
            Keyword.has_key?(meta_kv, :expected_delimiter) and
            message_starts_with?(message, "missing interpolation terminator:") ->
          :interpolation_missing_terminator

        Keyword.has_key?(meta_kv, :opening_delimiter) and
            Keyword.has_key?(meta_kv, :expected_delimiter) and
            message_starts_with?(message, "missing terminator:") ->
          :terminator_missing_closer

        message_starts_with?(message, "unexpected ( after alias") ->
          :alias_unexpected_paren

        message_starts_with?(message, "expected %{ to define a map, got %(") or
            message_starts_with?(message, "expected %{ to define a map, got %[") ->
          :map_invalid_open_delimiter

        message_starts_with?(message, "keyword argument must be followed by space") ->
          :keyword_missing_space_after_colon

        message_starts_with?(message, "unexpected space between % and {") ->
          :map_unexpected_space_after_percent

        message_starts_with?(message, "invalid float number") ->
          :number_invalid_float

        true ->
          :syntax_error
      end

    %__MODULE__{
      code: code,
      domain: infer_domain(code),
      token_display: flatten_chars(token_chars),
      position: position_from_meta(meta_kv),
      details: details_from_meta(meta_kv)
    }
  end

  def ensure_struct(atom) when is_atom(atom) do
    %__MODULE__{code: infer_code_from_atom(atom), domain: :general, details: %{legacy_atom: atom}}
  end

  def ensure_struct(other) do
    # Fallback: keep information for debugging during migration
    %__MODULE__{code: :syntax_error, details: %{legacy: other}}
  end

  # -- Internal helpers -------------------------------------------------------

  @spec meta_from(t()) :: keyword()
  defp meta_from(%__MODULE__{position: {{sl, sc}, {el, ec}}} = error) when is_integer(sl) do
    base = [line: sl, column: sc, end_line: el, end_column: ec]

    case error.code do
      :terminator_mismatched_closer ->
        details = error.details
        base ++
          [
            error_type: :mismatched_delimiter,
            opening_delimiter: Map.get(details, :opening_delimiter),
            closing_delimiter: Map.get(details, :closing_delimiter),
            expected_delimiter: Map.get(details, :expected_delimiter)
          ]

      :terminator_missing_closer ->
        details = error.details
        [
          opening_delimiter: Map.get(details, :opening_delimiter),
          expected_delimiter: Map.get(details, :expected_delimiter),
          line: Map.get(details, :start_line, sl),
          column: Map.get(details, :start_column, sc),
          end_line: el,
          end_column: ec
        ]

      :interpolation_missing_terminator ->
        # Use details start position if provided, else current
        [
          opening_delimiter: Map.get(error.details, :opening_delimiter, :"{"),
          expected_delimiter: Map.get(error.details, :expected_delimiter, :"{"),
          line: Map.get(error.details, :start_line, sl),
          column: Map.get(error.details, :start_column, sc),
          end_line: el,
          end_column: ec
        ]

      _ ->
        base
    end
  end

  defp meta_from(%__MODULE__{} = error) do
    # No explicit position; fall back to details if present
    case error.code do
      :terminator_missing_closer ->
        details = error.details
        [
          opening_delimiter: Map.get(details, :opening_delimiter),
          expected_delimiter: Map.get(details, :expected_delimiter),
          line: Map.get(details, :start_line, 1),
          column: Map.get(details, :start_column, 1),
          end_line: Map.get(details, :end_line, Map.get(details, :start_line, 1)),
          end_column: Map.get(details, :end_column, Map.get(details, :start_column, 1))
        ]

      _ ->
        [line: 1, column: 1, end_line: 1, end_column: 1]
    end
  end

  defp details_from_meta(meta_kv) do
    # Extract a subset of known keys
    keys = [
      :opening_delimiter,
      :expected_delimiter,
      :closing_delimiter,
      :hint_line
    ]

    Enum.reduce(keys, %{}, fn k, acc ->
      case Keyword.fetch(meta_kv, k) do
        {:ok, v} -> Map.put(acc, k, v)
        :error -> acc
      end
    end)
  end

  defp position_from_meta(meta_kv) when is_list(meta_kv) do
    with {:ok, sl} <- Keyword.fetch(meta_kv, :line),
         {:ok, sc} <- Keyword.fetch(meta_kv, :column),
         {:ok, el} <- Keyword.fetch(meta_kv, :end_line),
         {:ok, ec} <- Keyword.fetch(meta_kv, :end_column) do
      {{sl, sc}, {el, ec}}
    else
      _ -> nil
    end
  end

  # defp infer_domain(:terminator_unexpected_closer), do: :terminator
  defp infer_domain(:terminator_mismatched_closer), do: :terminator
  defp infer_domain(:terminator_missing_closer), do: :terminator
  # defp infer_domain(:reserved_unexpected_end), do: :reserved
  defp infer_domain(:interpolation_missing_terminator), do: :interpolation
  # defp infer_domain(:interpolation_not_allowed_in_quoted_identifier), do: :interpolation
  # defp infer_domain(:string_missing_terminator), do: :string
  # defp infer_domain(:heredoc_missing_terminator), do: :heredoc
  # defp infer_domain(:heredoc_invalid_header), do: :heredoc
  # defp infer_domain(:sigil_invalid_name), do: :sigil
  # defp infer_domain(:sigil_invalid_delimiter), do: :sigil
  defp infer_domain(:map_unexpected_space_after_percent), do: :map
  defp infer_domain(:map_invalid_open_delimiter), do: :map
  defp infer_domain(:keyword_missing_space_after_colon), do: :keyword
  # defp infer_domain(:keyword_do_with_fn_invalid), do: :keyword
  # defp infer_domain(:identifier_empty), do: :identifier
  # defp infer_domain(:identifier_mixed_script), do: :identifier
  # defp infer_domain(:identifier_confusable), do: :identifier
  # defp infer_domain(:identifier_nfkc_needed), do: :identifier
  # defp infer_domain(:identifier_unexpected_token), do: :identifier
  # defp infer_domain(:identifier_invalid_char), do: :identifier
  # defp infer_domain(:identifier_atom_length_limit), do: :identifier
  # defp infer_domain(:identifier_nonexistent_atom_when_existing_only), do: :identifier
  # defp infer_domain(:alias_invalid_character), do: :alias
  defp infer_domain(:alias_unexpected_paren), do: :alias
  # defp infer_domain(:reserved_token_used), do: :reserved
  # defp infer_domain(:number_trailing_garbage), do: :number
  defp infer_domain(:number_invalid_float), do: :number
  # defp infer_domain(:encoding_invalid), do: :encoding
  # defp infer_domain(:comment_invalid_bidi), do: :comment
  # defp infer_domain(:comment_invalid_linebreak), do: :comment
  # defp infer_domain(:vc_merge_conflict_marker), do: :vc
  # defp infer_domain(:unexpected_token), do: :general
  defp infer_domain(:syntax_error), do: :general

  defp infer_code_from_atom(:vc_marker), do: :vc_merge_conflict_marker
  defp infer_code_from_atom(:invalid_sigil_name), do: :sigil_invalid_name
  defp infer_code_from_atom(:invalid_sigil_delimiter), do: :sigil_invalid_delimiter
  defp infer_code_from_atom(:invalid_char_after_heredoc_open), do: :heredoc_invalid_header
  defp infer_code_from_atom(:invalid_character_after_number), do: :number_trailing_garbage
  defp infer_code_from_atom(:invalid_float), do: :number_invalid_float
  defp infer_code_from_atom(:unexpected_token_after_alias), do: :alias_unexpected_paren
  defp infer_code_from_atom(:unexpected_reserved_word), do: :reserved_unexpected_end
  defp infer_code_from_atom(:unexpected_token_terminator), do: :terminator_unexpected_closer
  defp infer_code_from_atom(:unexpected_token_or_reserved), do: :reserved_unexpected_end
  defp infer_code_from_atom(_), do: :syntax_error

  defp message_starts_with?(message, prefix) when is_binary(prefix) do
    bin = iodata_to_binary_safe(message)
    String.starts_with?(bin, prefix)
  rescue
    _ -> false
  end

  defp iodata_to_binary_safe(message) do
    IO.iodata_to_binary(message)
  rescue
    _ -> ""
  end

  defp flatten_chars(nil), do: []
  defp flatten_chars(list) when is_list(list), do: List.flatten(list)
  defp flatten_chars(other) when is_binary(other), do: String.to_charlist(other)
  defp flatten_chars(_), do: []

  defp terminator_chars(delimiter) when is_atom(delimiter) do
    delimiter
    |> Atom.to_string()
    |> String.to_charlist()
  end

  defp terminator_chars(delimiter) when is_list(delimiter), do: delimiter

  # -- Details validation -----------------------------------------------------
  defp validate_details!(%__MODULE__{code: :terminator_mismatched_closer, details: d}),
    do: require_keys!(d, [:opening_delimiter, :closing_delimiter, :expected_delimiter])

  defp validate_details!(%__MODULE__{code: :terminator_missing_closer, details: d}),
    do: require_keys!(d, [:opening_delimiter, :expected_delimiter])

  defp validate_details!(%__MODULE__{code: :map_invalid_open_delimiter, details: _d}), do: :ok
  defp validate_details!(%__MODULE__{code: :map_unexpected_space_after_percent, details: _d}), do: :ok
  defp validate_details!(%__MODULE__{code: :string_missing_terminator, details: _d}), do: :ok
  defp validate_details!(%__MODULE__{code: :heredoc_missing_terminator, details: _d}), do: :ok
  defp validate_details!(%__MODULE__{code: _}), do: :ok

  defp require_keys!(map, keys) do
    Enum.each(keys, fn k ->
      unless Map.has_key?(map, k) do
        raise ArgumentError, "Missing required details key: #{inspect(k)}"
      end
    end)
    :ok
  end
end
