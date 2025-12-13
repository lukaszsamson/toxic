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
  # Terminators
  @type code ::
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
          | :identifier_static_atoms_encoder_error
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
          # General fallback and syntax errors
          | :unexpected_token
          | :syntax_error
          | :syntax_consecutive_semicolons

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
  def format(%__MODULE__{code: code, token_display: tok})
      when code in [
             :terminator_mismatched_closer,
             :terminator_unexpected_closer
           ] do
    case List.wrap(tok) do
      ~c"end" -> ~c"unexpected reserved word: "
      _ -> ~c"unexpected token: "
    end
  end

  # Special case: Elixir prints only "unexpected token: " and puts descriptive part in token_chars
  def format(%__MODULE__{code: :unexpected_token, token_display: _tok}) do
    ~c"unexpected token: "
  end

  def format(%__MODULE__{code: :syntax_error, details: d}) when is_map(d) do
    # Best-effort: preserve legacy message when available; otherwise use a generic message.
    Map.get(d, :legacy_message, ~c"syntax error")
  end

  def format(%__MODULE__{code: :terminator_missing_closer, details: details}) do
    expected = Map.fetch!(details, :expected_delimiter)
    chars = terminator_chars(expected)
    msg = :io_lib.format(~c"missing terminator: ~ts", [chars])

    case Map.get(details, :hint_iolist) do
      nil -> msg
      hint -> [msg, hint]
    end
  end

  def format(%__MODULE__{code: :string_missing_terminator, details: details}) do
    # Escape-at-EOF errors in Elixir show a distinct message:
    # "invalid escape \\ at end of file"
    if Map.get(details, :escape_at_eof?, false) do
      ~c"invalid escape \\ at end of file"
    else
      expected = Map.get(details, :expected_delimiter, Map.get(details, :opening_delimiter))
      chars = terminator_chars(expected)
      msg = :io_lib.format(~c"missing terminator: ~ts", [chars])
      suffix = Map.get(details, :suffix_iolist, [])
      [msg, suffix]
    end
  end

  def format(%__MODULE__{code: :heredoc_missing_terminator, details: details}) do
    expected = Map.get(details, :expected_delimiter, Map.get(details, :opening_delimiter))
    chars = terminator_chars(expected)
    msg = :io_lib.format(~c"missing terminator: ~ts", [chars])
    suffix = Map.get(details, :suffix_iolist, [])
    [msg, suffix]
  end

  def format(%__MODULE__{code: :interpolation_missing_terminator, details: d}) do
    base = :io_lib.format(~c"missing interpolation terminator: \"~ts\"", [[?}]])
    suffix = Map.get(d, :suffix_iolist, [])
    [base, suffix]
  end

  def format(%__MODULE__{code: :interpolation_not_allowed_in_quoted_identifier}) do
    ~c"interpolation is not allowed when calling function/macro. Found interpolation in a call starting with: "
  end

  def format(%__MODULE__{code: :keyword_missing_space_after_colon}) do
    ~c"keyword argument must be followed by space after: "
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

  def format(%__MODULE__{code: :reserved_unexpected_end, token_display: ~c"do", details: d}) do
    # Special extended help for stray do (non-fn case)
    suffix = Map.get(d, :help_iolist, [])
    {~c"unexpected reserved word: ", suffix}
  end

  def format(%__MODULE__{code: :reserved_unexpected_end, details: d}) do
    # Check for suffix (e.g., indentation hint for "end")
    case Map.get(d, :suffix_iolist) do
      nil -> ~c"unexpected reserved word: end"
      [] -> ~c"unexpected reserved word: end"
      suffix -> {~c"unexpected reserved word: ", suffix}
    end
  end

  def format(%__MODULE__{code: :heredoc_invalid_header, details: %{delim: delim} = d}) do
    base = ~c"heredoc allows only whitespace characters followed by a new line after opening "

    if Map.get(d, :message_excludes_delim?, false) do
      base
    else
      [base, List.wrap(delim)]
    end
  end

  def format(%__MODULE__{code: :alias_unexpected_paren, details: d}) do
    alias_name = Map.get(d, :alias, "")
    alias_str = if alias_name != "", do: " #{alias_name}", else: ""

    [
      ~c"unexpected ( after alias",
      String.to_charlist(alias_str),
      ~c". Function names and identifiers in Elixir start with lowercase characters or underscore. For example:\n\n",
      ~c"    hello_world()\n",
      ~c"    _starting_with_underscore()\n",
      ~c"    numb3rs_are_allowed()\n",
      ~c"    may_finish_with_question_mark?()\n",
      ~c"    may_finish_with_exclamation_mark!()\n\n",
      ~c"Unexpected token: "
    ]
  end

  def format(%__MODULE__{code: :alias_invalid_character, details: d, token_display: _tok}) do
    Map.get(d, :message_iolist, ~c"invalid character in alias: ")
  end

  def format(%__MODULE__{code: :number_trailing_garbage, details: d}) do
    # Use prebuilt message captured at error site; fallback to generic
    Map.get(d, :msg_iolist, ~c"invalid character after number")
  end

  def format(%__MODULE__{code: :number_invalid_float}) do
    # Elixir includes a trailing space so the offending literal is shown via token_chars
    ~c"invalid float number "
  end

  def format(%__MODULE__{code: :sigil_invalid_name}) do
    ~c"invalid sigil name, it should be either a one-letter lowercase letter or an uppercase letter optionally followed by uppercase letters and digits, got: "
  end

  def format(%__MODULE__{code: :sigil_invalid_delimiter}) do
    ~c"invalid sigil delimiter: "
  end

  def format(%__MODULE__{code: :comment_invalid_bidi, domain: :comment}) do
    ~c"invalid bidirectional formatting character in comment: "
  end

  def format(%__MODULE__{code: :comment_invalid_bidi, domain: :string, token_display: tok}) do
    [
      ~c"invalid bidirectional formatting character in string: ",
      List.wrap(tok),
      ~c". If you want to use such character, use it in its escaped ",
      List.wrap(tok),
      ~c" form instead"
    ]
  end

  def format(%__MODULE__{code: :comment_invalid_linebreak, domain: :comment}) do
    ~c"invalid line break character in comment: "
  end

  def format(%__MODULE__{code: :comment_invalid_linebreak, domain: :string, token_display: tok}) do
    [
      ~c"invalid line break character in string: ",
      List.wrap(tok),
      ~c". If you want to use such character, use it in its escaped ",
      List.wrap(tok),
      ~c" form instead"
    ]
  end

  def format(%__MODULE__{code: :vc_merge_conflict_marker}) do
    ~c"found an unexpected version control marker, please resolve the conflicts: "
  end

  def format(%__MODULE__{code: :identifier_mixed_script, details: d}) do
    prefix = Map.get(d, :message_prefix, ~c"invalid mixed-script identifier found: ")
    suffix = Map.get(d, :message_suffix, [])
    {prefix, suffix}
  end

  def format(%__MODULE__{code: :identifier_invalid_char, details: d}) do
    Map.get(d, :msg_iolist, ~c"invalid character in identifier: ")
  end

  def format(%__MODULE__{code: :reserved_token_used}) do
    ~c"reserved token: "
  end

  def format(%__MODULE__{code: :keyword_do_with_fn_invalid, details: %{help_iolist: help}}) do
    {~c"unexpected reserved word: ", help}
  end

  def format(%__MODULE__{code: :identifier_nonexistent_atom_when_existing_only}) do
    ~c"unsafe atom does not exist: "
  end

  def format(%__MODULE__{code: :identifier_unexpected_token}) do
    ~c"unexpected token: "
  end

  def format(%__MODULE__{code: :identifier_atom_length_limit}) do
    ~c"atom length must be less than system limit: "
  end

  def format(%__MODULE__{code: :encoding_invalid}) do
    ~c"invalid encoding in atom: "
  end

  def format(%__MODULE__{code: :identifier_static_atoms_encoder_error, details: d})
      when is_map(d) do
    reason = Map.get(d, :reason, ~c"static atoms encoder error")
    [List.wrap(reason), ~c": "]
  end

  def format(%__MODULE__{code: :syntax_consecutive_semicolons}) do
    ~c"unexpected token: "
  end

  @doc """
  Migration/compatibility bridge.

  Ensures tolerant mode can work with legacy Elixir-style reason tuples
  (for example `{meta_kv, message_iodata, token_chars}`) without crashing.
  """
  @spec ensure_struct(t() | {term(), term(), term()} | term()) :: t()
  def ensure_struct(%__MODULE__{} = err), do: err

  # Legacy strict reason tuple: `{meta_kv, message, token_chars}`
  def ensure_struct({meta_kv, message, token_chars}) when is_list(meta_kv) do
    meta_map = Map.new(meta_kv)

    line = Map.get(meta_map, :line, 1)
    column = Map.get(meta_map, :column, 1)
    end_line = Map.get(meta_map, :end_line)
    end_column = Map.get(meta_map, :end_column)

    position =
      if is_integer(end_line) and is_integer(end_column) do
        {{line, column}, {end_line, end_column}}
      else
        nil
      end

    # Prefer non-message-based classification using meta keys when present.
    {code, domain, details} =
      cond do
        meta_map[:error_type] == :mismatched_delimiter ->
          {
            :terminator_mismatched_closer,
            :terminator,
            %{
              opening_delimiter: meta_map[:opening_delimiter],
              closing_delimiter: meta_map[:closing_delimiter],
              expected_delimiter: meta_map[:expected_delimiter]
            }
          }

        true ->
          # Fallback: preserve location + legacy message for display/debugging.
          {
            :syntax_error,
            :general,
            %{line: line, column: column, legacy_message: message, legacy_meta: meta_kv}
          }
      end

    %__MODULE__{
      code: code,
      domain: domain,
      position: position,
      token_display: List.wrap(token_chars),
      details: details
    }
  end

  # Any other legacy shape: wrap as a generic syntax error.
  def ensure_struct(other) do
    %__MODULE__{
      code: :syntax_error,
      domain: :general,
      token_display: [],
      details: %{legacy: other}
    }
  end

  @doc """
  Safe details validation for tolerant mode.

  Returns the original error when valid; otherwise returns a `:syntax_error` wrapper
  describing the validation failure. This guarantees tolerant mode never crashes
  due to malformed error structs.
  """
  @spec safe_validate(t()) :: t()
  def safe_validate(%__MODULE__{} = error) do
    try do
      validate_details!(error)
      error
    rescue
      e in ArgumentError ->
        {line, column} = primary_line_column(error)

        %__MODULE__{
          code: :syntax_error,
          domain: :general,
          token_display: [],
          details: %{
            line: line,
            column: column,
            validation_error: Exception.message(e),
            original_code: error.code,
            original_domain: error.domain
          }
        }
    end
  end

  @doc """
  Safe variant of `to_reason_tuple/1`.

  Needed for tolerant mode when `error_token_payload` is `:tuple` or `:both`.
  """
  @spec safe_to_reason_tuple(t()) :: {keyword(), iodata(), iodata() | []}
  def safe_to_reason_tuple(%__MODULE__{} = error) do
    try do
      to_reason_tuple(error)
    rescue
      e in ArgumentError ->
        {line, column} = primary_line_column(error)
        {[line: line, column: column], [~c"invalid error details: ", Exception.message(e)], []}
    end
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
        :reserved_unexpected_end -> format(error)
        _ -> format(error)
      end

    # Decide whether to place separator/token in `token_chars` per legacy conventions
    token_chars =
      case error.code do
        :terminator_mismatched_closer -> List.wrap(error.token_display)
        :terminator_unexpected_closer -> List.wrap(error.token_display)
        :interpolation_missing_terminator -> []
        :interpolation_not_allowed_in_quoted_identifier -> List.wrap(error.token_display)
        :reserved_unexpected_end -> List.wrap(error.token_display)
        :string_missing_terminator -> []
        :heredoc_invalid_header -> List.wrap(error.token_display)
        :keyword_missing_space_after_colon -> List.wrap(error.token_display)
        :keyword_do_with_fn_invalid -> List.wrap(error.token_display)
        :comment_invalid_bidi -> List.wrap(error.token_display)
        :comment_invalid_linebreak -> List.wrap(error.token_display)
        :sigil_invalid_name -> List.wrap(error.token_display)
        :sigil_invalid_delimiter -> List.wrap(error.token_display)
        :map_invalid_open_delimiter -> List.wrap(error.token_display)
        :map_unexpected_space_after_percent -> List.wrap(error.token_display)
        :number_trailing_garbage -> List.wrap(error.token_display)
        :number_invalid_float -> List.wrap(error.token_display)
        :identifier_mixed_script -> List.wrap(error.token_display)
        :identifier_invalid_char -> List.wrap(error.token_display)
        :identifier_unexpected_token -> List.wrap(error.token_display)
        :identifier_atom_length_limit -> List.wrap(error.token_display)
        :identifier_nonexistent_atom_when_existing_only -> List.wrap(error.token_display)
        :identifier_static_atoms_encoder_error -> List.wrap(error.token_display)
        :encoding_invalid -> List.wrap(error.token_display)
        :alias_invalid_character -> List.wrap(error.token_display)
        :alias_unexpected_paren -> List.wrap(error.token_display)
        :reserved_token_used -> List.wrap(error.token_display)
        :vc_merge_conflict_marker -> List.wrap(error.token_display)
        :unexpected_token -> List.wrap(error.token_display)
        :syntax_consecutive_semicolons -> List.wrap(error.token_display)
        _ -> []
      end

    {meta_kv, message, token_chars}
  end

  defp primary_line_column(%__MODULE__{position: {{sl, sc}, _}})
       when is_integer(sl) and is_integer(sc),
       do: {sl, sc}

  defp primary_line_column(%__MODULE__{details: d}) when is_map(d),
    do: {Map.get(d, :line, 1), Map.get(d, :column, 1)}

  # -- Internal helpers -------------------------------------------------------

  @spec meta_from(t()) :: keyword()
  defp meta_from(%__MODULE__{position: {{sl, sc}, {el, ec}}} = error) when is_integer(sl) do
    details = error.details

    base =
      case error.code do
        :terminator_mismatched_closer ->
          # Elixir's legacy reason tuples place the span from the opener to the
          # start of the mismatched closer.
          [
            line: Map.get(details, :line, sl),
            column: Map.get(details, :column, sc),
            end_line: Map.get(details, :end_line, el),
            end_column: Map.get(details, :end_column, ec)
          ]

        _ ->
          [line: sl, column: sc, end_line: el, end_column: ec]
      end

    case error.code do
      :terminator_mismatched_closer ->
        base ++
          [
            error_type: :mismatched_delimiter,
            opening_delimiter: Map.get(details, :opening_delimiter),
            closing_delimiter: Map.get(details, :closing_delimiter),
            expected_delimiter: Map.get(details, :expected_delimiter)
          ]

      _ ->
        base
    end
  end

  defp meta_from(%__MODULE__{} = error) do
    # No explicit position; fall back to details if present
    details = error.details

    # Extract line/column from details with fallback to 1
    line = Map.get(details, :line, 1)
    column = Map.get(details, :column, 1)

    # Only include end_line/end_column if explicitly in details
    # Elixir doesn't add them for most simple errors
    base_position = [line: line, column: column]

    case error.code do
      :terminator_missing_closer ->
        # This needs explicit end position from details
        [
          opening_delimiter: Map.get(details, :opening_delimiter),
          expected_delimiter: Map.get(details, :expected_delimiter),
          line: Map.get(details, :start_line, line),
          column: Map.get(details, :start_column, column),
          end_line: Map.get(details, :end_line, line),
          end_column: Map.get(details, :end_column, column)
        ]

      :terminator_mismatched_closer ->
        # This code path shouldn't happen (should have position set)
        # But if it does, include delimiter info
        base_position ++
          [
            error_type: :mismatched_delimiter,
            opening_delimiter: Map.get(details, :opening_delimiter),
            closing_delimiter: Map.get(details, :closing_delimiter),
            expected_delimiter: Map.get(details, :expected_delimiter)
          ]

      :interpolation_missing_terminator ->
        # Uses start position from details if available
        [
          opening_delimiter: Map.get(details, :opening_delimiter, :"{"),
          expected_delimiter: Map.get(details, :expected_delimiter, :"{"),
          line: Map.get(details, :start_line, line),
          column: Map.get(details, :start_column, column),
          end_line: Map.get(details, :end_line, line),
          end_column: Map.get(details, :end_column, column)
        ]

      code when code in [:string_missing_terminator, :heredoc_missing_terminator] ->
        # String/heredoc/sigil missing terminators need delimiter info
        [
          opening_delimiter: Map.get(details, :opening_delimiter),
          expected_delimiter:
            Map.get(details, :expected_delimiter, Map.get(details, :opening_delimiter)),
          line: Map.get(details, :start_line, line),
          column: Map.get(details, :start_column, column),
          end_line: Map.get(details, :end_line, line),
          end_column: Map.get(details, :end_column, column)
        ]

      :interpolation_not_allowed_in_quoted_identifier ->
        # Use start_line and start_column from details (position of interpolation start)
        [
          line: Map.get(details, :start_line, line),
          column: Map.get(details, :start_column, column)
        ]

      _ ->
        # Most errors: just [line: X, column: Y] to match Elixir
        base_position
    end
  end

  defp terminator_chars(delimiter) when is_atom(delimiter) do
    delimiter
    |> Atom.to_charlist()
  end

  # -- Details validation -----------------------------------------------------
  # Validators check that required details keys are present for each error code.
  # This catches malformed errors at construction time rather than during formatting.

  @doc """
  Validates that required details are present for the given error code.
  Raises ArgumentError if required keys are missing.

  Called automatically by to_reason_tuple/1.
  Can also be called directly to verify error construction.
  """
  @spec validate_details!(t()) :: :ok
  def validate_details!(%__MODULE__{code: :terminator_mismatched_closer, details: d}),
    do: require_keys!(d, [:opening_delimiter, :closing_delimiter, :expected_delimiter])

  def validate_details!(%__MODULE__{code: :terminator_missing_closer, details: d}),
    do:
      require_keys!(d, [
        :opening_delimiter,
        :expected_delimiter,
        :line,
        :column,
        :end_line,
        :end_column
      ])

  def validate_details!(%__MODULE__{code: :terminator_unexpected_closer, details: _d}), do: :ok

  # :reserved_unexpected_end may or may not have opening_delimiter/expected_delimiter
  # (genuinely unexpected end has no opener, mismatched end has opener from driver)
  def validate_details!(%__MODULE__{code: :reserved_unexpected_end, details: _d}), do: :ok

  # String/Interpolation/Heredoc errors
  def validate_details!(%__MODULE__{code: :string_missing_terminator, details: d}) do
    # Special case: escape-at-EOF errors have minimal details
    if Map.get(d, :escape_at_eof?, false) do
      require_keys!(d, [:line, :column])
    else
      require_keys!(d, [
        :opening_delimiter,
        :expected_delimiter,
        :line,
        :column,
        :end_line,
        :end_column,
        :suffix_iolist
      ])
    end
  end

  def validate_details!(%__MODULE__{code: :heredoc_missing_terminator, details: d}),
    do:
      require_keys!(d, [
        :opening_delimiter,
        :expected_delimiter,
        :line,
        :column,
        :end_line,
        :end_column,
        :suffix_iolist
      ])

  def validate_details!(%__MODULE__{code: :interpolation_missing_terminator, details: d}),
    do:
      require_keys!(d, [
        :opening_delimiter,
        :expected_delimiter,
        :start_line,
        :start_column,
        :end_line,
        :end_column,
        :suffix_iolist
      ])

  def validate_details!(%__MODULE__{
        code: :interpolation_not_allowed_in_quoted_identifier,
        details: d
      }),
      do: require_keys!(d, [:start_line, :start_column])

  # Map and keyword errors
  def validate_details!(%__MODULE__{code: :map_invalid_open_delimiter, details: _d}), do: :ok

  def validate_details!(%__MODULE__{code: :map_unexpected_space_after_percent, details: _d}),
    do: :ok

  def validate_details!(%__MODULE__{code: :keyword_missing_space_after_colon, details: _d}),
    do: :ok

  # Alias errors
  def validate_details!(%__MODULE__{code: :alias_invalid_character, details: d}),
    do: require_keys!(d, [:message_iolist])

  def validate_details!(%__MODULE__{code: :alias_unexpected_paren, details: _d}), do: :ok

  # Catch-all for codes without specific validation requirements
  def validate_details!(%__MODULE__{code: _}), do: :ok

  defp require_keys!(map, keys) do
    Enum.each(keys, fn k ->
      unless Map.has_key?(map, k) do
        raise ArgumentError, "Missing required details key: #{inspect(k)}"
      end
    end)

    :ok
  end
end
