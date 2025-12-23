defmodule Toxic.Token do
  @moduledoc """
  Macros for working with raw Toxic tokens.

  Tokens are tuples with the following shapes:
  - 2-tuple: `{kind, meta}` - simple tokens (punctuation, keywords)
  - 3-tuple: `{kind, meta, value}` - tokens with values (literals, operators, identifiers)
  - 4-tuple: `{kind, meta, v1, v2}` - special tokens like `not in`

  Meta has the format: `{{start_line, start_col}, {end_line, end_col}, extra}`
  """

  # ============================================================================
  # Meta construction macros
  # ============================================================================

  @doc "Build meta for single-line token with given length"
  defmacro meta(line, column, length, extra) do
    quote do
      {{unquote(line), unquote(column)}, {unquote(line), unquote(column) + unquote(length)},
       unquote(extra)}
    end
  end

  @doc "Build meta with explicit start and end positions"
  defmacro meta(line, column, end_line, end_column, extra) do
    quote do
      {{unquote(line), unquote(column)}, {unquote(end_line), unquote(end_column)}, unquote(extra)}
    end
  end

  # ============================================================================
  # Token pattern matching macros - for matching/extracting from raw tokens
  # ============================================================================

  @doc """
  Match a 2-tuple token `{kind, meta}` and bind kind and meta.
  Used for punctuation and simple keywords like `do`, `end`, `fn`, `true`, `false`, `nil`.

  ## Example
      defp handle(token(kind, meta)) when kind in [:"(", :")"], do: ...
  """
  defmacro token(kind, meta) do
    quote do
      {unquote(kind), unquote(meta)}
    end
  end

  @doc """
  Match a 3-tuple token `{kind, meta, value}` and bind all components.
  Used for literals, operators, identifiers, etc.

  ## Example
      defp handle(token(kind, meta, value)) when kind == :identifier, do: ...
  """
  defmacro token(kind, meta, value) do
    quote do
      {unquote(kind), unquote(meta), unquote(value)}
    end
  end

  @doc """
  Match a 4-tuple token `{kind, meta, v1, v2}` and bind all components.
  Used for special tokens like `not in`.

  ## Example
      defp handle(token(kind, meta, v1, v2)) when kind == :in_op, do: ...
  """
  defmacro token(kind, meta, v1, v2) do
    quote do
      {unquote(kind), unquote(meta), unquote(v1), unquote(v2)}
    end
  end

  @doc """
  Match meta and bind start line, start column, end line, end column, and extra.

  ## Example
      defp get_line(token(_kind, meta(sl, sc, _el, _ec, _extra))), do: sl
  """
  defmacro meta_pos(start_line, start_col, end_line, end_col, extra) do
    quote do
      {{unquote(start_line), unquote(start_col)}, {unquote(end_line), unquote(end_col)},
       unquote(extra)}
    end
  end

  # ============================================================================
  # Kind extraction - works with any token tuple size
  # ============================================================================

  @doc """
  Extract the kind from a raw token (works for 2/3/4-tuples).

  ## Example
      iex> Toxic.Token.kind({:identifier, meta, :foo})
      :identifier
  """
  @spec kind(tuple()) :: atom()
  def kind({kind, _meta}), do: kind
  def kind({kind, _meta, _value}), do: kind
  def kind({kind, _meta, _v1, _v2}), do: kind

  @doc """
  Guard-safe check if token has the given kind.

  ## Example
      defp handle(tok) when is_kind(tok, :identifier), do: ...
  """
  defmacro is_kind(token, expected_kind) do
    quote do
      is_tuple(unquote(token)) and elem(unquote(token), 0) == unquote(expected_kind)
    end
  end

  # ============================================================================
  # Meta extraction
  # ============================================================================

  @doc """
  Extract the meta from a raw token.

  ## Example
      iex> Toxic.Token.meta({:identifier, {{1, 1}, {1, 4}, nil}, :foo})
      {{1, 1}, {1, 4}, nil}
  """
  @spec meta(tuple()) :: tuple()
  def meta({_kind, meta}), do: meta
  def meta({_kind, meta, _value}), do: meta
  def meta({_kind, meta, _v1, _v2}), do: meta

  @doc "Extract start line from meta"
  @spec start_line(tuple()) :: pos_integer()
  def start_line({{line, _col}, _end, _extra}), do: line

  @doc "Extract start column from meta"
  @spec start_col(tuple()) :: pos_integer()
  def start_col({{_line, col}, _end, _extra}), do: col

  @doc "Extract end line from meta"
  @spec end_line(tuple()) :: pos_integer()
  def end_line({_start, {line, _col}, _extra}), do: line

  @doc "Extract end column from meta"
  @spec end_col(tuple()) :: pos_integer()
  def end_col({_start, {_line, col}, _extra}), do: col

  @doc "Extract extra field from meta"
  @spec extra(tuple()) :: term()
  def extra({_start, _end, extra}), do: extra

  @doc "Extract line from token (start line)"
  @spec line(tuple()) :: pos_integer()
  def line(token), do: token |> meta() |> start_line()

  @doc "Extract column from token (start column)"
  @spec column(tuple()) :: pos_integer()
  def column(token), do: token |> meta() |> start_col()

  # ============================================================================
  # Value extraction
  # ============================================================================

  @doc """
  Extract the value from a raw token.
  Returns nil for 2-tuple tokens that have no value.

  ## Example
      iex> Toxic.Token.value({:identifier, meta, :foo})
      :foo
      iex> Toxic.Token.value({:"(", meta})
      nil
  """
  @spec value(tuple()) :: term()
  def value({_kind, _meta}), do: nil
  def value({_kind, _meta, value}), do: value
  def value({_kind, _meta, v1, _v2}), do: v1

  @doc """
  Extract parsed value from numeric tokens (stored in meta.extra).
  For :int and :flt tokens, the parsed value is in meta.extra.

  ## Example
      iex> Toxic.Token.parsed_value({:int, {{1,1}, {1,4}, 123}, ~c"123"})
      123
  """
  @spec parsed_value(tuple()) :: number() | nil
  def parsed_value({kind, {_start, _end, parsed}, _repr}) when kind in [:int, :flt], do: parsed
  def parsed_value(_), do: nil

  # ============================================================================
  # Newline count extraction (for :eol, :";", :",", and operators)
  # ============================================================================

  @doc """
  Extract newline count from a token.
  For :eol, :";", and :",", the count is in meta.extra.
  For operators, the count may also be in meta.extra.
  Returns 0 for tokens without newline info.

  ## Example
      iex> Toxic.Token.newlines({:eol, {{1, 10}, {2, 1}, 1}})
      1
  """
  @spec newlines(tuple()) :: non_neg_integer()
  def newlines({kind, {_, _, count}}) when kind in [:eol, :";", :","] and is_integer(count),
    do: count

  # Literals encode parsed values in extra, not newline counts
  def newlines({kind, _meta, _value}) when kind in [:int, :flt, :char], do: 0

  # 3-tuple tokens with newline count in extra
  def newlines({_kind, {_, _, count}, _value}) when is_integer(count), do: count

  # 4-tuple tokens with newline count in extra
  def newlines({_kind, {_, _, count}, _v1, _v2}) when is_integer(count), do: count

  def newlines(_), do: 0

  # ============================================================================
  # Specific token construction macros (kept from original)
  # ============================================================================

  @tokens_3 ~w(int flt char atom kw_identifier)a

  for token <- @tokens_3 do
    defmacro unquote(token)(meta, original_representation) do
      tok = unquote(token)

      quote do
        {unquote(tok), unquote(meta), unquote(original_representation)}
      end
    end
  end

  defmacro alias_token(meta, original_representation) do
    quote do
      {:alias, unquote(meta), unquote(original_representation)}
    end
  end

  defmacro dot_token(meta) do
    quote do
      {:., unquote(meta)}
    end
  end

  # ============================================================================
  # Additional token construction/matching macros for common patterns
  # ============================================================================

  @doc "Match/construct an identifier token"
  defmacro identifier(meta, name) do
    quote do
      {:identifier, unquote(meta), unquote(name)}
    end
  end

  @doc "Match/construct a paren_identifier token"
  defmacro paren_identifier(meta, name) do
    quote do
      {:paren_identifier, unquote(meta), unquote(name)}
    end
  end

  @doc "Match/construct a bracket_identifier token"
  defmacro bracket_identifier(meta, name) do
    quote do
      {:bracket_identifier, unquote(meta), unquote(name)}
    end
  end

  @doc "Match/construct a do_identifier token"
  defmacro do_identifier(meta, name) do
    quote do
      {:do_identifier, unquote(meta), unquote(name)}
    end
  end

  @doc "Match/construct an op_identifier token"
  defmacro op_identifier(meta, name) do
    quote do
      {:op_identifier, unquote(meta), unquote(name)}
    end
  end

  @doc "Match/construct an eol token"
  defmacro eol(meta) do
    quote do
      {:eol, unquote(meta)}
    end
  end

  @doc "Match/construct a semicolon token"
  defmacro semicolon(meta) do
    quote do
      {:";", unquote(meta)}
    end
  end

  @doc "Match/construct a comma token"
  defmacro comma(meta) do
    quote do
      {:",", unquote(meta)}
    end
  end

  # ============================================================================
  # Operator token matching - generic macro that works with any operator kind
  # ============================================================================

  @doc """
  Match/construct any operator token by kind.

  ## Example
      # Match any dual_op token
      defp handle(operator(:dual_op, meta, op)), do: ...

      # Construct a match_op token
      operator(:match_op, meta, :=)
  """
  defmacro operator(kind, meta, op_value) do
    quote do
      {unquote(kind), unquote(meta), unquote(op_value)}
    end
  end

  # Delimiter macros
  @delimiters [
    {:open_paren, :"("},
    {:close_paren, :")"},
    {:open_bracket, :"["},
    {:close_bracket, :"]"},
    {:open_curly, :"{"},
    {:close_curly, :"}"},
    {:open_bitstring, :"<<"},
    {:close_bitstring, :">>"}
  ]

  for {name, kind} <- @delimiters do
    @doc "Match/construct a #{kind} delimiter token"
    defmacro unquote(name)(meta) do
      k = unquote(kind)

      quote do
        {unquote(k), unquote(meta)}
      end
    end
  end

  # Block keywords
  @doc "Match/construct a :do token"
  defmacro do_kw(meta) do
    quote do
      {:do, unquote(meta)}
    end
  end

  @doc "Match/construct an :end token"
  defmacro end_kw(meta) do
    quote do
      {:end, unquote(meta)}
    end
  end

  @doc "Match/construct a :fn token"
  defmacro fn_kw(meta) do
    quote do
      {:fn, unquote(meta)}
    end
  end

  @doc "Match/construct a block_identifier token (after, else, catch, rescue)"
  defmacro block_identifier(meta, name) do
    quote do
      {:block_identifier, unquote(meta), unquote(name)}
    end
  end

  # ============================================================================
  # Token kind guards
  # ============================================================================

  @identifier_kinds [:identifier, :paren_identifier, :bracket_identifier, :do_identifier, :op_identifier]

  @doc "Guard: is this an identifier-like token kind?"
  defmacro is_identifier_kind(kind) do
    kinds = @identifier_kinds

    quote do
      unquote(kind) in unquote(kinds)
    end
  end

  @operator_kinds [
    :unary_op,
    :dual_op,
    :mult_op,
    :rel_op,
    :comp_op,
    :and_op,
    :or_op,
    :xor_op,
    :concat_op,
    :arrow_op,
    :power_op,
    :range_op,
    :in_match_op,
    :type_op,
    :stab_op,
    :match_op,
    :pipe_op,
    :ellipsis_op,
    :ternary_op,
    :assoc_op,
    :at_op,
    :capture_op,
    :when_op,
    :in_op,
    :dot_call_op
  ]

  @doc "Guard: is this an operator token kind?"
  defmacro is_operator_kind(kind) do
    kinds = @operator_kinds

    quote do
      unquote(kind) in unquote(kinds)
    end
  end

  @literal_kinds [:int, :flt, :char, :atom, true, false, nil]

  @doc "Guard: is this a literal token kind?"
  defmacro is_literal_kind(kind) do
    kinds = @literal_kinds

    quote do
      unquote(kind) in unquote(kinds)
    end
  end

  @delimiter_kinds [:"(", :")", :"[", :"]", :"{", :"}", :"<<", :">>"]

  @doc "Guard: is this a delimiter token kind?"
  defmacro is_delimiter_kind(kind) do
    kinds = @delimiter_kinds

    quote do
      unquote(kind) in unquote(kinds)
    end
  end
end
