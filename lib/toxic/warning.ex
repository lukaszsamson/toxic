defmodule Toxic.Warning do
  @moduledoc """
  Structured warning representation for Toxic tokenizer.

  Warnings are emitted during tokenization to indicate deprecated syntax,
  ambiguous constructs, invalid escape sequences, or unicode/character issues
  that don't prevent tokenization but should be brought to the user's attention.

  ## Structure

  Each warning has:
  - `code`: Unique atom identifying the specific warning type
  - `domain`: Category grouping related warnings
  - `token_display`: Visual representation of the problematic token
  - `details`: Additional context including position and suggestions

  ## Example

      warning = Toxic.Warning.deprecated_single_quote_atom(1, 5)
      # => %Toxic.Warning{
      #      code: :deprecated_single_quote_atom,
      #      domain: :deprecated,
      #      token_display: ~c":'atom'",
      #      details: %{line: 1, column: 5, suggestion: ~c"Use double quotes: :\\"atom\\""}
      #    }
  """

  @type domain ::
          :deprecated
          | :ambiguous
          | :escape
          | :unicode
          | :identifier
          | :atom

  # Deprecated
  @type code ::
          :deprecated_single_quote_atom
          | :deprecated_charlist
          | :deprecated_xor_operator
          | :deprecated_bnot_operator
          | :deprecated_pipe_operator
          | :deprecated_sigil_escape
          | :deprecated_single_quote_keyword
          | :deprecated_single_quote_call
          | :unnecessary_quoted_keyword
          | :unnecessary_quoted_call
          | :unnecessary_quoted_atom
          # Ambiguous
          | :ambiguous_bang_before_equals
          | :ambiguous_question_before_equals
          | :confusable_repeated_operator
          | :ambiguous_triple_colon_atom
          # Escape
          | :invalid_char_escape
          | :unnecessary_char_escape
          # Unicode
          | :non_latin_atom
          | :confusable_identifier_char

  @type t :: %__MODULE__{
          code: code(),
          domain: domain(),
          token_display: iolist(),
          details: map()
        }

  defstruct [:code, :domain, :token_display, :details]

  @doc """
  Create a new warning with structured metadata.

  ## Parameters

  - `code`: Unique identifier for the warning type
  - `domain`: Category grouping (e.g., :deprecated, :ambiguous)
  - `token_display`: Visual representation of the problematic token
  - `details`: Map containing line, column, and other contextual information

  ## Example

      Toxic.Warning.new(
        :deprecated_single_quote_atom,
        :deprecated,
        ~c":'atom'",
        %{line: 1, column: 5, suggestion: ~c"Use double quotes"}
      )
  """
  def new(code, domain, token_display, details) do
    %__MODULE__{
      code: code,
      domain: domain,
      token_display: token_display,
      details: details
    }
  end

  # Deprecated syntax warnings

  @doc """
  Warning for deprecated single-quoted atoms.

  Single quotes around atoms are deprecated in favor of double quotes.

  ## Example

      # Input: :'atom'
      deprecated_single_quote_atom(1, 5)
  """
  def deprecated_single_quote_atom(line, column) do
    new(
      :deprecated_single_quote_atom,
      :deprecated,
      ~c":'atom'",
      %{line: line, column: column, suggestion: ~c"Use double quotes: :\"atom\""}
    )
  end

  @doc """
  Warning for deprecated charlist syntax.

  Charlists should use the ~c sigil or be replaced with binary strings.

  ## Examples

      # Input: 'charlist'
      deprecated_charlist(1, 5, ~c"'charlist'")

      # For detailed migration message (single-quoted strings)
      deprecated_charlist_detailed(1, 5)
  """
  def deprecated_charlist(line, column, token_display) do
    new(
      :deprecated_charlist,
      :deprecated,
      token_display,
      %{line: line, column: column, suggestion: ~c"Use ~c sigil or binary string"}
    )
  end

  @doc """
  Warning for deprecated charlist with detailed migration message.

  Provides full migration instructions including mix format command.

  ## Example

      # Input: 'charlist'
      deprecated_charlist_detailed(1, 5)
  """
  def deprecated_charlist_detailed(line, column) do
    msg =
      ~c"using single-quoted strings to represent charlists is deprecated.\n" ++
        ~c"Use ~c\"\" if you indeed want a charlist or use \"\" instead.\n" ++
        ~c"You may run \"mix format --migrate\" to change all single-quoted\n" ++
        ~c"strings to use the ~c sigil and fix this warning."

    new(
      :deprecated_charlist,
      :deprecated,
      ~c"'...'",
      %{line: line, column: column, message: msg}
    )
  end

  @doc """
  Warning for deprecated ^^^ operator.

  The ^^^ operator is deprecated as it's typically used as xor but has wrong precedence.

  ## Example

      # Input: a ^^^ b
      deprecated_xor_operator(1, 3)
  """
  def deprecated_xor_operator(line, column) do
    new(
      :deprecated_xor_operator,
      :deprecated,
      ~c"^^^",
      %{
        line: line,
        column: column,
        message:
          ~c"^^^ is deprecated. It is typically used as xor but it has the wrong precedence, use Bitwise.bxor/2 instead"
      }
    )
  end

  @doc """
  Warning for deprecated ~~~ operator.

  The ~~~ operator is deprecated in favor of Bitwise.bnot/1 for clarity.

  ## Example

      # Input: ~~~a
      deprecated_bnot_operator(1, 1)
  """
  def deprecated_bnot_operator(line, column) do
    new(
      :deprecated_bnot_operator,
      :deprecated,
      ~c"~~~",
      %{
        line: line,
        column: column,
        message: ~c"~~~ is deprecated. Use Bitwise.bnot/1 instead for clarity"
      }
    )
  end

  @doc """
  Warning for deprecated <|> operator.

  The <|> operator is deprecated in favor of other pipe-like operators.

  ## Example

      # Input: a <|> b
      deprecated_pipe_operator(line, column)
  """
  def deprecated_pipe_operator(line, column) do
    new(
      :deprecated_pipe_operator,
      :deprecated,
      ~c"<|>",
      %{
        line: line,
        column: column,
        message: ~c"<|> is deprecated. Use another pipe-like operator"
      }
    )
  end

  @doc """
  Warning for deprecated sigil escape sequence.

  Using backslash to escape the closing delimiter of an uppercase sigil is deprecated.

  ## Example

      # Input: ~S"foo\""
      deprecated_sigil_escape(1, 5, ?")
  """
  def deprecated_sigil_escape(line, column, delimiter) do
    msg =
      :io_lib.format(
        ~c"using \\~ts to escape the closing of an uppercase sigil is deprecated, please use another delimiter or a lowercase sigil instead",
        [[delimiter]]
      )

    new(
      :deprecated_sigil_escape,
      :deprecated,
      [?\\, delimiter],
      %{line: line, column: column, delimiter: delimiter, message: msg}
    )
  end

  @doc """
  Warning for deprecated single quotes around keywords.

  ## Example

      # Input: 'hello': value
      deprecated_single_quote_keyword(1, 1)
  """
  def deprecated_single_quote_keyword(line, column) do
    new(
      :deprecated_single_quote_keyword,
      :deprecated,
      ~c"'keyword':",
      %{
        line: line,
        column: column,
        message: ~c"single quotes around keywords are deprecated. Use double quotes instead"
      }
    )
  end

  @doc """
  Warning for deprecated single quotes around calls.

  ## Example

      # Input: Foo.'bar'
      deprecated_single_quote_call(line, column)
  """
  def deprecated_single_quote_call(line, column) do
    new(
      :deprecated_single_quote_call,
      :deprecated,
      ~c".'call'",
      %{
        line: line,
        column: column,
        message: ~c"single quotes around calls are deprecated. Use double quotes instead"
      }
    )
  end

  @doc """
  Warning for unnecessary quotes around keywords.

  ## Example

      # Input: "hello": value (where quotes aren't needed)
      unnecessary_quoted_keyword(1, 1, ~c"hello")
  """
  def unnecessary_quoted_keyword(line, column, keyword) do
    msg =
      :io_lib.format(
        ~c"found quoted keyword \"~ts\" but the quotes are not required. " ++
          ~c"Note that keywords are always atoms, even when quoted. " ++
          ~c"Similar to atoms, keywords made exclusively of ASCII " ++
          ~c"letters, numbers, and underscores and not beginning with a " ++
          ~c"number do not require quotes",
        [keyword]
      )

    new(
      :unnecessary_quoted_keyword,
      :deprecated,
      keyword,
      %{line: line, column: column, keyword: keyword, message: msg}
    )
  end

  @doc """
  Warning for unnecessary quotes around calls.

  ## Example

      # Input: Foo."bar" (where quotes aren't needed)
      unnecessary_quoted_call(1, 5, ~c"bar")
  """
  def unnecessary_quoted_call(line, column, call_name) do
    msg =
      :io_lib.format(
        ~c"found quoted call \"~ts\" but the quotes are not required. " ++
          ~c"Calls made exclusively of Unicode letters, numbers, and underscores " ++
          ~c"and not beginning with a number do not require quotes",
        [call_name]
      )

    new(
      :unnecessary_quoted_call,
      :deprecated,
      call_name,
      %{line: line, column: column, call_name: call_name, message: msg}
    )
  end

  @doc """
  Warning for unnecessary quotes around atoms.

  ## Example

      # Input: :"hello" (where quotes aren't needed)
      unnecessary_quoted_atom(1, 1, ~c"hello")
  """
  def unnecessary_quoted_atom(line, column, atom) do
    msg =
      :io_lib.format(
        ~c"found quoted atom \"~ts\" but the quotes are not required. " ++
          ~c"Atoms made exclusively of ASCII letters, numbers, underscores, " ++
          ~c"beginning with a letter or underscore, and optionally ending with ! or ? " ++
          ~c"do not require quotes",
        [atom]
      )

    new(
      :unnecessary_quoted_atom,
      :deprecated,
      atom,
      %{line: line, column: column, atom: atom, message: msg}
    )
  end

  # Ambiguous syntax warnings

  @doc """
  Warning for ambiguous bang before equals.

  An identifier ending with `!` followed by `=` is ambiguous - it could mean
  `identifier! =` or `identifier !=`.

  ## Example

      # Input: foo! = bar
      ambiguous_bang_before_equals(1, 5, ~c"foo!", :identifier)
  """
  def ambiguous_bang_before_equals(line, column, identifier, kind) do
    msg =
      :io_lib.format(
        ~c"found ~ts \"~ts\", ending with \"!\", followed by =. " ++
          ~c"It is unclear if you mean \"~ts !=\" or \"~ts =\". Please add " ++
          ~c"a space before or after ! to remove the ambiguity",
        [kind_name(kind), identifier, :lists.droplast(identifier), identifier]
      )

    new(
      :ambiguous_bang_before_equals,
      :ambiguous,
      identifier,
      %{line: line, column: column, kind: kind, message: msg}
    )
  end

  @doc """
  Warning for ambiguous question mark before equals.

  An identifier ending with `?` followed by `=` is ambiguous - it could mean
  `identifier? =` or `identifier ?=` (hypothetically).

  ## Example

      # Input: foo? = bar
      ambiguous_question_before_equals(1, 5, ~c"foo?", :identifier)
  """
  def ambiguous_question_before_equals(line, column, identifier, kind) do
    msg =
      :io_lib.format(
        ~c"found ~ts \"~ts\", ending with \"?\", followed by =. " ++
          ~c"It is unclear if you mean \"~ts\" as a predicate or \"~ts =\". " ++
          ~c"Please add a space before or after ? to remove the ambiguity",
        [kind_name(kind), identifier, identifier, identifier]
      )

    new(
      :ambiguous_question_before_equals,
      :ambiguous,
      identifier,
      %{line: line, column: column, kind: kind, message: msg}
    )
  end

  @doc """
  Warning for confusable repeated operators.

  When an operator is immediately followed by the same character, it can be
  visually confusing. For example, `+++` could be `++ +` or `+ ++`.

  ## Example

      # Input: +++
      confusable_repeated_operator(1, 5, ~c"++", ?+)
  """
  def confusable_repeated_operator(line, column, operator, next_char) do
    token_str = List.to_string(operator)
    char_str = List.to_string([next_char])

    msg =
      :io_lib.format(
        ~c"found \"~ts\" followed by \"~ts\", please use a space between \"~ts\" and the next \"~ts\"",
        [token_str, char_str, token_str, char_str]
      )

    new(
      :confusable_repeated_operator,
      :ambiguous,
      operator ++ [next_char],
      %{line: line, column: column, operator: operator, next_char: next_char, message: msg}
    )
  end

  @doc """
  Warning for ambiguous triple-colon atom.

  The atom `:::` must be written between quotes to avoid ambiguity with
  the `::` type operator.

  ## Example

      # Input: :::
      ambiguous_triple_colon_atom(1, 5)
  """
  def ambiguous_triple_colon_atom(line, column) do
    new(
      :ambiguous_triple_colon_atom,
      :ambiguous,
      ~c":::",
      %{
        line: line,
        column: column,
        message: ~c"atom ::: must be written between quotes, as in :\"::\", to avoid ambiguity"
      }
    )
  end

  # Escape sequence warnings

  @doc """
  Warning for invalid character escape sequences.

  Unknown escape sequences in character literals should not use backslash.

  ## Example

      # Input: ?\\a (where \\a is not a valid escape)
      invalid_char_escape(1, 5, ?a)
  """
  def invalid_char_escape(line, column, char) do
    msg = :io_lib.format(~c"unknown escape sequence ?\\~tc, use ?~tc instead", [char, char])

    new(
      :invalid_char_escape,
      :escape,
      [??, ?\\, char],
      %{line: line, column: column, char: char, message: msg}
    )
  end

  @doc """
  Warning for unnecessary character escape sequences.

  Some characters don't need to be escaped and should be written directly.

  ## Example

      # Input: ?\\a (where \\a could be written as ?a)
      unnecessary_char_escape(1, 5, ?a, [?a], ~c"LATIN SMALL LETTER A")
  """
  def unnecessary_char_escape(line, column, char, escape_seq, name) do
    msg =
      :io_lib.format(
        ~c"found ?\\ followed by code point 0x~.16B (~ts), please use ?~ts instead",
        [char, name, escape_seq]
      )

    new(
      :unnecessary_char_escape,
      :escape,
      [??, ?\\, char],
      %{line: line, column: column, char: char, escape: escape_seq, name: name, message: msg}
    )
  end

  # Unicode warnings

  @doc """
  Warning for non-Latin atoms.

  Atoms containing non-Latin characters may cause portability or readability issues.

  ## Example

      # Input: :café
      non_latin_atom(1, 5, :café)
  """
  def non_latin_atom(line, column, atom) do
    new(
      :non_latin_atom,
      :unicode,
      Atom.to_charlist(atom),
      %{line: line, column: column, atom: atom}
    )
  end

  @doc """
  Warning for confusable identifier characters.

  Some unicode characters look similar to ASCII characters but are different,
  which can lead to confusing bugs.

  ## Example

      # Input: fοo (where ο is Greek omicron, not ASCII o)
      confusable_identifier_char(1, 5, ~c"fοo", ?ο)
  """
  def confusable_identifier_char(line, column, identifier, confusable_char) do
    new(
      :confusable_identifier_char,
      :unicode,
      identifier,
      %{line: line, column: column, confusable: confusable_char}
    )
  end

  # Helper functions

  defp kind_name(:atom), do: ~c"atom"
  defp kind_name(:identifier), do: ~c"identifier"
end
