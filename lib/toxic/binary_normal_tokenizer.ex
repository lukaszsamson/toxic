defmodule Toxic.BinaryNormalTokenizer do
  @moduledoc """
  Binary-based normal tokenizer for Elixir source code.

  This module provides the same functionality as Toxic.NormalTokenizer but
  operates on binaries instead of charlists for improved performance.
  """
  alias Toxic.BinaryNormalTokenizer
  alias Toxic.BinaryNormalTokenizer.{Identifier, Alias, Number, Dot, Terminator, Sigil, Comment}
  import Toxic.CharacterClassifier
  import Toxic.Token
  import Toxic.BinaryNormalTokenizer.Operator

  import Toxic.Util,
    only: [
      strip_horizontal_space_bin: 2,
      no_token: 4,
      reset_eol: 4,
      emit: 5,
      emit_with_eol: 5,
      emit_op_identifier: 5
    ]

  import Toxic.Scope, except: [track_ascii: 2]

  # VC merge conflict
  def next(<<?<, ?<, ?<, ?<, ?<, ?<, ?<, _::binary>> = original, line, 1, _scope, _lookbehind) do
    first_line = original |> String.split(~r/[\n\r]/, parts: 2) |> hd() |> String.to_charlist()

    err = %Toxic.Error{
      code: :vc_merge_conflict_marker,
      domain: :vc,
      token_display: first_line,
      details: %{line: line, column: 1}
    }

    {:error, err}
  end

  # Base integers

  def next(<<?0, ?x, h, rest::binary>>, line, column, scope, _lookbehind) when is_hex(h) do
    {rest, number, original_representation, length} = Number.tokenize_hex(rest, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  def next(<<?0, ?b, h, rest::binary>>, line, column, scope, _lookbehind) when is_bin(h) do
    {rest, number, original_representation, length} = Number.tokenize_bin(rest, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  def next(<<?0, ?o, h, rest::binary>>, line, column, scope, _lookbehind) when is_octal(h) do
    {rest, number, original_representation, length} = Number.tokenize_octal(rest, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  # Comments

  def next(<<?#, string::binary>>, line, column, scope, lookbehind) do
    case Comment.tokenize_comment(string, [?#]) do
      {:error, {code, char}} when code in [:comment_invalid_bidi, :comment_invalid_linebreak] ->
        token = :io_lib.format("\\u~4.16.0B", [char])

        err = %Toxic.Error{
          code: code,
          domain: :comment,
          token_display: token,
          details: %{line: line, column: column}
        }

        {:error, err}

      {rest, comment} ->
        Comment.preserve_comments(line, column, lookbehind, comment, rest, scope)

        case prev_token(lookbehind) do
          {:eol, _meta, _} -> reset_eol(rest, line, column, scope)
          _ -> no_token(rest, line, column, scope)
        end
    end
  end

  # Sigils

  def next(<<?~, h, _::binary>> = original, line, column, scope, lookbehind)
      when is_upcase(h) or is_downcase(h) do
    Sigil.tokenize_sigil(original, line, column, scope, lookbehind)
  end

  # Char tokens

  def next(<<??, ?\\, h, rest::binary>>, line, column, scope, _lookbehind) do
    char = Toxic.Unescape.unescape_map(h)

    new_scope =
      if h == char and h != ?\\ do
        case handle_char(char) do
          {escape, name} ->
            warning = Toxic.Warning.unnecessary_char_escape(line, column, char, escape, name)
            Toxic.Scope.prepend_warning(warning, scope)

          false when is_downcase(h) or is_upcase(h) ->
            warning = Toxic.Warning.invalid_char_escape(line, column, h)
            Toxic.Scope.prepend_warning(warning, scope)

          false ->
            scope
        end
      else
        scope
      end

    scope(column: base_column) = scope

    {token, rest, new_line, new_column} =
      case h do
        ?\n ->
          # ?\\\n - escaped newline
          {char(meta(line, column, line + 1, base_column, [??, ?\\, ?\n]), char), rest, line + 1,
           base_column}

        _ ->
          # Regular escaped char
          {char(meta(line, column, 3, [??, ?\\, h]), char), rest, line, column + 3}
      end

    emit(token, rest, new_line, new_column, new_scope)
  end

  def next(<<??, char::utf8, rest::binary>>, line, column, scope, _lookbehind) do
    new_scope =
      case handle_char(char) do
        {escape, name} ->
          warning = Toxic.Warning.unnecessary_char_escape(line, column, char, escape, name)
          Toxic.Scope.prepend_warning(warning, scope)

        false ->
          scope
      end

    scope(column: base_column) = scope

    {token, rest, new_line, new_column} =
      case char do
        ?\n ->
          # ?\n - raw newline character
          {char(meta(line, column, line + 1, base_column, [??, ?\n]), char), rest, line + 1,
           base_column}

        _ ->
          # Regular char
          {char(meta(line, column, 2, [??, char]), char), rest, line, column + 2}
      end

    emit(token, rest, new_line, new_column, new_scope)
  end

  # Heredocs

  def next(<<?", ?", ?", rest::binary>>, line, column, scope, lookbehind) do
    BinaryNormalTokenizer.String.handle_heredocs(rest, line, column, ?", scope, lookbehind)
  end

  def next(<<?', ?', ?', rest::binary>>, line, column, scope, lookbehind) do
    BinaryNormalTokenizer.String.handle_heredocs(rest, line, column, ?', scope, lookbehind)
  end

  # Strings

  def next(<<?", rest::binary>>, line, column, scope, lookbehind) do
    BinaryNormalTokenizer.String.handle_strings(rest, line, column + 1, ?", scope, lookbehind)
  end

  def next(<<?', rest::binary>>, line, column, scope, lookbehind) do
    BinaryNormalTokenizer.String.handle_strings(rest, line, column + 1, ?', scope, lookbehind)
  end

  # Operator atoms (., <<>>, %{}, %, &, {}, ..//)
  for chars <- ~w(. <<>> %{} % & {} ..//)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1
    pattern = IO.iodata_to_binary(chars)

    def next(<<unquote(pattern), ?:, ws, rest::binary>>, line, column, scope, _lookbehind)
        when is_space(ws) do
      token = kw_identifier(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, <<ws, rest::binary>>, line, column + unquote(length), scope)
    end
  end

  for chars <- ~w(<<>> %{} % {} ..//)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1
    pattern = IO.iodata_to_binary(chars)

    def next(<<?:, unquote(pattern), rest::binary>>, line, column, scope, _lookbehind) do
      token = atom(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  defp op_atom3(?+, ?+, ?+), do: :+++
  defp op_atom3(?-, ?-, ?-), do: :---
  defp op_atom3(?<, ?<, ?<), do: :<<<
  defp op_atom3(?>, ?>, ?>), do: :>>>
  defp op_atom3(?~, ?>, ?>), do: :~>>
  defp op_atom3(?<, ?<, ?~), do: :<<~
  defp op_atom3(?<, ?~, ?>), do: :<~>
  defp op_atom3(?<, ?|, ?>), do: :"<|>"
  defp op_atom3(?&, ?&, ?&), do: :&&&
  defp op_atom3(?|, ?|, ?|), do: :|||
  defp op_atom3(?=, ?=, ?=), do: :===
  defp op_atom3(?!, ?=, ?=), do: :!==
  defp op_atom3(?., ?., ?.), do: :...
  defp op_atom3(?~, ?~, ?~), do: :"~~~"
  defp op_atom3(?^, ?^, ?^), do: :"^^^"

  defp op_atom2(?., ?.), do: :..
  defp op_atom2(?+, ?+), do: :++
  defp op_atom2(?-, ?-), do: :--
  defp op_atom2(?<, ?>), do: :<>
  defp op_atom2(?*, ?*), do: :**
  defp op_atom2(?|, ?>), do: :|>
  defp op_atom2(?~, ?>), do: :~>
  defp op_atom2(?<, ?~), do: :<~
  defp op_atom2(?<, ?=), do: :<=
  defp op_atom2(?>, ?=), do: :>=
  defp op_atom2(?=, ?=), do: :==
  defp op_atom2(?=, ?~), do: :=~
  defp op_atom2(?!, ?=), do: :!=
  defp op_atom2(?/, ?/), do: :"//"
  defp op_atom2(?&, ?&), do: :&&
  defp op_atom2(?|, ?|), do: :||
  defp op_atom2(?<, ?-), do: :<-
  defp op_atom2(?\\, ?\\), do: :"\\\\"
  defp op_atom2(?-, ?>), do: :->
  defp op_atom2(?:, ?:), do: :"::"

  defp op_atom1(?@), do: :@
  defp op_atom1(?&), do: :&
  defp op_atom1(?!), do: :!
  defp op_atom1(?^), do: :^
  defp op_atom1(?+), do: :+
  defp op_atom1(?-), do: :-
  defp op_atom1(?*), do: :*
  defp op_atom1(?/), do: :/
  defp op_atom1(?<), do: :<
  defp op_atom1(?>), do: :>
  defp op_atom1(?=), do: :=
  defp op_atom1(?|), do: :|
  defp op_atom1(?.), do: :.

  # Three Token Operators
  def next(<<?:, t1, t2, t3, rest::binary>>, line, column, scope, _lookbehind)
      when unary_op3(t1, t2, t3) or comp_op3(t1, t2, t3) or and_op3(t1, t2, t3) or
             or_op3(t1, t2, t3) or
             arrow_op3(t1, t2, t3) or xor_op3(t1, t2, t3) or concat_op3(t1, t2, t3) or
             ellipsis_op3(t1, t2, t3) do
    token = atom(meta(line, column, 4, nil), op_atom3(t1, t2, t3))
    emit(token, rest, line, column + 4, scope)
  end

  # Two Token Operators

  def next(<<?:, ?:, ?:, rest::binary>>, line, column, scope, _lookbehind) do
    warning = Toxic.Warning.ambiguous_triple_colon_atom(line, column)
    new_scope = Toxic.Scope.prepend_warning(warning, scope)
    token = atom(meta(line, column, 3, nil), :"::")
    emit(token, rest, line, column + 3, new_scope)
  end

  def next(<<?:, t1, t2, rest::binary>>, line, column, scope, _lookbehind)
      when comp_op2(t1, t2) or rel_op2(t1, t2) or and_op(t1, t2) or or_op(t1, t2) or
             arrow_op(t1, t2) or in_match_op(t1, t2) or concat_op(t1, t2) or power_op(t1, t2) or
             stab_op(t1, t2) or range_op(t1, t2) do
    token = atom(meta(line, column, 3, nil), op_atom2(t1, t2))
    emit(token, rest, line, column + 3, scope)
  end

  # Single Token Operators
  def next(<<?:, t, rest::binary>>, line, column, scope, _lookbehind)
      when at_op(t) or unary_op(t) or capture_op(t) or dual_op(t) or mult_op(t) or
             rel_op(t) or match_op(t) or pipe_op(t) or t == ?. do
    token = atom(meta(line, column, 2, nil), op_atom1(t))
    emit(token, rest, line, column + 2, scope)
  end

  # Stand-alone tokens

  def next(<<?=, ?>, rest::binary>>, line, column, scope, lookbehind) do
    token = {:assoc_op, meta(line, column, 2, previous_was_eol(lookbehind)), :"=>"}
    emit_with_eol(token, rest, line, column + 2, scope)
  end

  # Ternary operator

  def next(<<?., ?., ?/, ?/, _::binary>> = string, line, column, scope, _lookbehind) do
    <<_, _, _, _, rest::binary>> = string

    case strip_horizontal_space_bin(rest, 0) do
      {<<?/, _::binary>> = remaining, extra} ->
        token = {:identifier, meta(line, column, 4, nil), :..//}
        emit(token, remaining, line, column + 4 + extra, scope)

      {_, _} ->
        <<h, _::binary>> = string
        {:error, unexpected_token_reason(h, line, column)}
    end
  end

  # Three token operators
  @three_token_ops ~w(unary_op3 ellipsis_op3 comp_op3 and_op3 or_op3 xor_op3 concat_op3 arrow_op3)a
  @unary_three_token_ops ~w(unary_op3 ellipsis_op3)a

  for token <- @three_token_ops do
    token_name = token |> to_string() |> String.replace_suffix("3", "") |> String.to_atom()

    call =
      if token in @unary_three_token_ops do
        :handle_unary_op
      else
        :handle_op
      end

    def next(<<t1, t2, t3, rest::binary>>, line, column, scope, lookbehind)
        when unquote(token)(t1, t2, t3) do
      new_scope = maybe_warn_too_many_of_same_char([t1, t2, t3], rest, line, column, scope)

      unquote(call)(
        rest,
        line,
        column,
        unquote(token_name),
        3,
        op_atom3(t1, t2, t3),
        new_scope,
        lookbehind
      )
    end
  end

  # Containers + punctuation tokens
  def next(<<?,, rest::binary>>, line, column, scope, _lookbehind) do
    token = comma(meta(line, column, 1, 0))
    emit(token, rest, line, column + 1, scope)
  end

  def next(<<?<, ?<, rest::binary>>, line, column, scope, lookbehind) do
    token = open_bitstring(meta(line, column, 2, nil))
    Terminator.handle_terminator(rest, line, column + 2, scope, token, lookbehind)
  end

  def next(<<?>, ?>, rest::binary>>, line, column, scope, lookbehind) do
    token = close_bitstring(meta(line, column, 2, previous_was_eol(lookbehind)))
    Terminator.handle_terminator(rest, line, column + 2, scope, token, lookbehind)
  end

  def next(<<?{, _::binary>> = _rest, line, column, _scope, {{:%, _, _}, _, _}) do
    err = %Toxic.Error{
      code: :map_unexpected_space_after_percent,
      domain: :map,
      token_display: [?{],
      position: {{line, column}, {line, column + 1}},
      details: %{line: line, column: column}
    }

    {:error, err}
  end

  def next(<<t, rest::binary>>, line, column, scope, lookbehind) when t in [?(, ?{, ?[] do
    token =
      case t do
        ?( -> token(:"(", meta(line, column, 1, nil), nil)
        ?{ -> token(:"{", meta(line, column, 1, nil), nil)
        ?[ -> token(:"[", meta(line, column, 1, nil), nil)
      end

    Terminator.handle_terminator(rest, line, column + 1, scope, token, lookbehind)
  end

  def next(<<t, rest::binary>>, line, column, scope, lookbehind) when t in [?), ?}, ?]] do
    token =
      case t do
        ?) -> token(:")", meta(line, column, 1, previous_was_eol(lookbehind)), nil)
        ?} -> token(:"}", meta(line, column, 1, previous_was_eol(lookbehind)), nil)
        ?] -> token(:"]", meta(line, column, 1, previous_was_eol(lookbehind)), nil)
      end

    Terminator.handle_terminator(rest, line, column + 1, scope, token, lookbehind)
  end

  # Two Token Operators
  def next(<<t1, t2, rest::binary>>, line, column, scope, lookbehind) when ternary_op(t1, t2) do
    op = op_atom2(t1, t2)
    token = {:ternary_op, meta(line, column, 2, previous_was_eol(lookbehind)), op}
    emit_with_eol(token, rest, line, column + 2, scope)
  end

  @two_token_ops ~w(power_op range_op concat_op arrow_op comp_op2 rel_op2 and_op or_op in_match_op type_op stab_op)a

  for token <- @two_token_ops do
    token_name = token |> to_string() |> String.replace_suffix("2", "") |> String.to_atom()

    def next(<<t1, t2, rest::binary>>, line, column, scope, lookbehind)
        when unquote(token)(t1, t2) do
      handle_op(
        rest,
        line,
        column,
        unquote(token_name),
        2,
        op_atom2(t1, t2),
        scope,
        lookbehind
      )
    end
  end

  # Single Token Operators

  def next(<<?&, rest::binary>>, line, column, scope, _lookbehind) do
    kind =
      case strip_horizontal_space_bin(rest, 0) do
        {<<int, _::binary>>, 0} when is_digit(int) ->
          :capture_int

        {<<?/, new_rest::binary>>, _} ->
          case strip_horizontal_space_bin(new_rest, 0) do
            {<<?/, _::binary>>, _} -> :capture_op
            {_, _} -> :identifier
          end

        {_, _} ->
          :capture_op
      end

    token = {kind, meta(line, column, 1, nil), :&}
    emit(token, rest, line, column + 1, scope)
  end

  @single_token_ops ~w(at_op unary_op rel_op dual_op mult_op match_op pipe_op)a
  @unary_single_token_ops ~w(at_op unary_op dual_op)a

  for token <- @single_token_ops do
    call =
      if token in @unary_single_token_ops do
        :handle_unary_op
      else
        :handle_op
      end

    def next(<<t, rest::binary>>, line, column, scope, lookbehind) when unquote(token)(t) do
      unquote(call)(rest, line, column, unquote(token), 1, op_atom1(t), scope, lookbehind)
    end
  end

  # Non-operator Atoms

  def next(
        <<?:, h, rest::binary>>,
        line,
        column,
        base_scope = scope(existing_atoms_only: existing_atoms_only),
        _lookbehind
      )
      when is_quote(h) do
    scope =
      if h == ?' do
        warning = Toxic.Warning.deprecated_single_quote_atom(line, column)
        Toxic.Scope.prepend_warning(warning, base_scope)
      else
        base_scope
      end

    {kind, start_type} =
      if(existing_atoms_only,
        do: {:atom_safe, :atom_safe_start},
        else: {:atom_unsafe, :atom_unsafe_start}
      )

    start_token = {start_type, meta(line, column, 2, nil), h}
    {{:switch_to_interp, start_token, kind, true, h}, rest, line, column + 2, scope}
  end

  def next(
        <<?:, _::binary>> = original,
        line,
        column,
        scope = scope(cursor_completion: cursor_completion),
        _lookbehind
      ) do
    <<_, string::binary>> = original

    case Identifier.tokenize_identifier(string, line, column, scope, false) do
      {_kind, unencoded, atom, rest, length, ascii?, _special} ->
        new_scope =
          maybe_warn_for_ambiguous_bang_before_equals(:atom, unencoded, rest, line, column, scope)

        tracked_scope = track_ascii(ascii?, new_scope)
        token = {:atom, meta(line, column, length + 1, unencoded), atom}
        emit(token, rest, line, column + 1 + length, tracked_scope)

      :empty when cursor_completion == false ->
        {:error, unexpected_token_reason(?:, line, column)}

      :empty ->
        # TODO: cursor completion
        no_token(<<>>, line, column, scope)

      {:unexpected_token, length} ->
        bad_bin = binary_part(string, length - 1, 1)
        <<bad, _::binary>> = bad_bin
        reason = unexpected_token_reason(bad, line, column + length - 1)

        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Integers and floats
  def next(<<h, rest::binary>>, line, column, scope, _lookbehind) when is_digit(h) do
    scope(cursor_completion: cursor_completion) = scope

    case Number.tokenize_number(rest, [h], 1, false) do
      {:error, reason, original} ->
        err = %Toxic.Error{
          code: :number_invalid_float,
          domain: :number,
          token_display: original,
          details: %{line: line, column: column, reason_iolist: reason}
        }

        {:error, err}

      {<<i, rest2::binary>>, number, _original, _length}
      when is_upcase(i) or is_downcase(i) or i == ?_ ->
        if number == 0 and i in [?x, ?0, ?b] and rest2 == <<>> and cursor_completion != false do
          no_token(<<>>, line, column, scope)
        else
          char_str = to_charlist(<<i::utf8>>)

          number_str =
            case number do
              int when is_integer(int) -> Integer.to_charlist(int)
              float when is_float(float) -> Float.to_charlist(float)
            end

          msg =
            ~c"invalid character \"" ++
              char_str ++
              ~c"\" after number " ++
              number_str ++
              ~c". If you intended to write a number, " ++
              ~c"make sure to separate the number from the character (using comma, space, etc). " ++
              ~c"If you meant to write a function name or a variable, note that identifiers in " ++
              ~c"Elixir cannot start with numbers. Unexpected token: "

          {:error,
           %Toxic.Error{
             code: :number_trailing_garbage,
             domain: :number,
             token_display: [i],
             details: %{line: line, column: column, msg_iolist: msg}
           }}
        end

      {rest2, number, original, length} when is_integer(number) ->
        token = int(meta(line, column, length, number), original)
        emit(token, rest2, line, column + length, scope)

      {rest2, number, original, length} ->
        token = flt(meta(line, column, length, number), original)
        emit(token, rest2, line, column + length, scope)
    end
  end

  # Spaces

  def next(<<t, rest::binary>>, line, column, scope, lookbehind) when is_horizontal_space(t) do
    {remaining, stripped} = strip_horizontal_space_bin(rest, 0)
    handle_space_sensitive_tokens(remaining, line, column + 1 + stripped, scope, lookbehind)
  end

  # End of line

  # Consecutive semicolons - emit error
  def next(<<?;, _::binary>> = _rest, line, column, _scope, {{:";", _, _}, _, _}) do
    token_display = [
      ?\",
      ?;,
      ?\",
      ?\s,
      ?(,
      ~c"column ",
      Integer.to_charlist(column),
      ~c", ",
      ~c"code point U+003B",
      ?)
    ]

    {:error,
     %Toxic.Error{
       code: :syntax_consecutive_semicolons,
       domain: :general,
       token_display: token_display,
       details: %{line: line, column: column}
     }}
  end

  def next(<<?;, rest::binary>>, line, column, scope, _lookbehind) do
    token = semicolon(meta(line, column, 1, 0))
    emit(token, rest, line, column + 1, scope)
  end

  def next(<<?\\>> = _original, line, column, _scope, _lookbehind) do
    {:error,
     %Toxic.Error{
       code: :string_missing_terminator,
       domain: :string,
       token_display: [],
       details: %{line: line, column: column, escape_at_eof?: true}
     }}
  end

  def next(<<?\\, ?\n>> = _original, line, column, _scope, _lookbehind) do
    {:error,
     %Toxic.Error{
       code: :string_missing_terminator,
       domain: :string,
       token_display: [],
       details: %{line: line, column: column, escape_at_eof?: true}
     }}
  end

  def next(<<?\\, ?\r, ?\n>> = _original, line, column, _scope, _lookbehind) do
    {:error,
     %Toxic.Error{
       code: :string_missing_terminator,
       domain: :string,
       token_display: [],
       details: %{line: line, column: column, escape_at_eof?: true}
     }}
  end

  def next(<<?\\, ?\n, rest::binary>>, line, _column, scope, _lookbehind) do
    {remaining, extra_newlines} = count_newlines_bin(rest, 0)
    tokenize_eol(remaining, line, scope, nil, extra_newlines)
  end

  def next(<<?\\, ?\r, ?\n, rest::binary>>, line, _column, scope, _lookbehind) do
    {remaining, extra_newlines} = count_newlines_bin(rest, 0)
    tokenize_eol(remaining, line, scope, nil, extra_newlines)
  end

  def next(<<?\n, rest::binary>>, line, column, scope, lookbehind) do
    {remaining, extra_newlines} = count_newlines_bin(rest, 0)

    tokenize_eol(
      remaining,
      line,
      scope,
      eol(line, column, scope, lookbehind, extra_newlines),
      extra_newlines
    )
  end

  def next(<<?\r, ?\n, rest::binary>>, line, column, scope, lookbehind) do
    {remaining, extra_newlines} = count_newlines_bin(rest, 0)

    tokenize_eol(
      remaining,
      line,
      scope,
      eol(line, column, scope, lookbehind, extra_newlines),
      extra_newlines
    )
  end

  # Others

  def next(<<?%, ?(, _::binary>> = _rest, line, column, _scope, _lookbehind) do
    err = %Toxic.Error{
      code: :map_invalid_open_delimiter,
      domain: :map,
      token_display: [?%, ?(],
      details: %{line: line, column: column}
    }

    {:error, err}
  end

  def next(<<?%, ?[, _::binary>> = _rest, line, column, _scope, _lookbehind) do
    err = %Toxic.Error{
      code: :map_invalid_open_delimiter,
      domain: :map,
      token_display: [?%, ?[],
      details: %{line: line, column: column}
    }

    {:error, err}
  end

  def next(
        <<?%, ?{, rest::binary>>,
        line,
        column,
        scope = scope(elixir_compatibility: elixir_compatibility),
        lookbehind
      ) do
    token =
      token(
        :"{",
        meta(line, if(elixir_compatibility, do: column, else: column + 1), 1, nil),
        nil
      )

    {_, rest, line, column, scope} =
      Terminator.handle_terminator(rest, line, column + 2, scope, token, lookbehind)

    {[
       {:token, token(:%{}, meta(line, column - 2, 1, nil), nil)},
       {:token, token}
     ], rest, line, column, scope}
  end

  def next(<<?%, rest::binary>>, line, column, scope, _lookbehind) do
    token = token(:%, meta(line, column, 1, nil), nil)
    emit(token, rest, line, column + 1, scope)
  end

  def next(<<?., rest::binary>>, line, column, scope, lookbehind) do
    Dot.tokenize_dot(rest, line, column + 1, meta(line, column, 1, nil), scope, lookbehind)
  end

  # Identifiers

  def next(
        string,
        line,
        column,
        original_scope = scope(cursor_completion: cursor_completion),
        lookbehind
      )
      when is_binary(string) and byte_size(string) > 0 do
    case Identifier.tokenize_identifier(
           string,
           line,
           column,
           original_scope,
           not previous_was_dot?(lookbehind)
         ) do
      {kind, unencoded, atom, rest, length, ascii, special} ->
        at? = :at in special
        scope = track_ascii(ascii, original_scope)

        case rest do
          <<?:, t, _::binary>> when is_space(t) ->
            token = {:kw_identifier, meta(line, column, length + 1, unencoded), atom}
            <<_, rest2::binary>> = rest
            emit(token, rest2, line, column + length + 1, scope)

          <<?:, t, _::binary>> when t != ?: ->
            atom_name = Atom.to_charlist(atom) ++ [?:]

            err = %Toxic.Error{
              code: :keyword_missing_space_after_colon,
              domain: :keyword,
              token_display: atom_name,
              details: %{line: line, column: column}
            }

            {:error, err}

          _ when at? ->
            msg =
              ~c"invalid character \"@\" (code point U+0040) in " ++
                to_charlist(to_string(kind)) ++ ~c": "

            {:error,
             %Toxic.Error{
               code: :identifier_invalid_char,
               domain: :identifier,
               token_display: Atom.to_charlist(atom),
               details: %{line: line, column: column, msg_iolist: msg}
             }}

          _ when atom in [:__aliases__, :__block__] ->
            {:error,
             %Toxic.Error{
               code: :reserved_token_used,
               domain: :reserved,
               token_display: Atom.to_charlist(atom),
               details: %{line: line, column: column}
             }}

          _ when kind == :alias ->
            Alias.tokenize_alias(
              rest,
              line,
              column,
              unencoded,
              atom,
              length,
              ascii,
              special,
              scope,
              lookbehind
            )

          _ when kind == :identifier ->
            new_scope =
              maybe_warn_for_ambiguous_bang_before_equals(
                :identifier,
                unencoded,
                rest,
                line,
                column,
                scope
              )

            token =
              Identifier.check_call_identifier(line, column, length, unencoded, atom, rest)

            emit(token, rest, line, column + length, new_scope)

          _ ->
            <<h, _::binary>> = string
            {:error, unexpected_token_reason(h, line, column)}
        end

      {:keyword, atom, type, rest, length} ->
        BinaryNormalTokenizer.Keyword.tokenize_keyword(
          type,
          rest,
          line,
          column,
          atom,
          length,
          original_scope,
          lookbehind
        )

      :empty when cursor_completion == false ->
        <<h, _::binary>> = string
        {:error, unexpected_token_reason(h, line, column)}

      :empty ->
        # TODO: cursor completion
        case string do
          <<?~, l>> when is_upcase(l) or is_downcase(l) ->
            no_token(<<>>, line, column, original_scope)

          <<?~>> ->
            no_token(<<>>, line, column, original_scope)

          _ ->
            <<h, _::binary>> = string
            {:error, unexpected_token_reason(h, line, column)}
        end

      {:unexpected_token, length} ->
        bad_bin = binary_part(string, length - 1, 1)
        <<bad, _::binary>> = bad_bin
        reason = unexpected_token_reason(bad, line, column + length - 1)

        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unexpected_token_reason(char, line, column) do
    message = unexpected_token_message(char, column)

    %Toxic.Error{
      code: :unexpected_token,
      domain: :general,
      token_display: message,
      details: %{line: line, column: column}
    }
  end

  defp unexpected_token_message(char, column) do
    case handle_char(char) do
      {_escaped, explanation} ->
        :io_lib.format("~ts (column ~p, code point U+~4.16.0B)", [explanation, column, char])

      false ->
        :io_lib.format("\"~ts\" (column ~p, code point U+~4.16.0B)", [[char], column, char])
    end
  end

  defp handle_char(0), do: {~c"\\0", ~c"null byte"}
  defp handle_char(7), do: {~c"\\a", ~c"alert"}
  defp handle_char(?\b), do: {~c"\\b", ~c"backspace"}
  defp handle_char(?\d), do: {~c"\\d", ~c"delete"}
  defp handle_char(?\e), do: {~c"\\e", ~c"escape"}
  defp handle_char(?\f), do: {~c"\\f", ~c"form feed"}
  defp handle_char(?\n), do: {~c"\\n", ~c"newline"}
  defp handle_char(?\r), do: {~c"\\r", ~c"carriage return"}
  defp handle_char(?\s), do: {~c"\\s", ~c"space"}
  defp handle_char(?\t), do: {~c"\\t", ~c"tab"}
  defp handle_char(?\v), do: {~c"\\v", ~c"vertical tab"}
  defp handle_char(_), do: false

  defp eol(_line, _column, _scope, {{token, _meta, _}, _, _}, _extra_newlines)
       when token in ~w(, ; eol)a do
    :increase_eol
  end

  defp eol(line, column, scope, _lookbehind, extra_newlines) do
    scope(column: base_column) = scope
    # Total count is 1 (for first newline) + extra_newlines
    {:eol, meta(line, column, line + 1 + extra_newlines, base_column, 1 + extra_newlines), nil}
  end

  # Count consecutive newlines (after the first one we already matched)
  # Returns {remaining_binary, count}
  defp count_newlines_bin(<<?\n, rest::binary>>, count) do
    count_newlines_bin(rest, count + 1)
  end

  defp count_newlines_bin(<<?\r, ?\n, rest::binary>>, count) do
    count_newlines_bin(rest, count + 1)
  end

  defp count_newlines_bin(rest, count) when is_binary(rest) do
    {rest, count}
  end

  defp tokenize_eol(rest, line, scope = scope(column: base_column), eol, extra_newlines)
       when is_binary(rest) do
    {stripped_rest, column} = strip_horizontal_space_bin(rest, base_column)
    indented_scope = scope(scope, indentation: column - 1)
    new_line = line + 1 + extra_newlines

    case eol do
      nil ->
        no_token(stripped_rest, new_line, column, indented_scope)

      :increase_eol ->
        increase_eol_by(stripped_rest, new_line, column, indented_scope, 1 + extra_newlines)

      eol_token ->
        emit(eol_token, stripped_rest, new_line, column, indented_scope)
    end
  end

  defp increase_eol_by(rest, line, column, scope, count) do
    {{:increase_eol_by, count}, rest, line, column, scope}
  end

  defp dual_op_atom(?+), do: :+
  defp dual_op_atom(?-), do: :-

  # Ambiguous unary/binary operators tokens
  defp handle_space_sensitive_tokens(
         <<sign, ?:, space, _::binary>> = string,
         line,
         column,
         scope,
         _lookbehind
       )
       when dual_op(sign) and is_space(space) do
    no_token(string, line, column, scope)
  end

  defp handle_space_sensitive_tokens(
         <<sign, not_marker, rest::binary>>,
         line,
         column,
         scope,
         {{token, _, _}, _, _}
       )
       when dual_op(sign) and not is_space(not_marker) and not_marker != sign and not_marker != ?/ and
              not_marker != ?> and token in [:identifier, :quoted_identifier_end] do
    rest2 = <<not_marker, rest::binary>>
    dual_op_token = {:dual_op, meta(line, column, 1, nil), dual_op_atom(sign)}
    emit_op_identifier(dual_op_token, rest2, line, column + 1, scope)
  end

  defp handle_space_sensitive_tokens(string, line, column, scope, _lookbehind)
       when is_binary(string) do
    no_token(string, line, column, scope)
  end

  # Warning helper functions

  def maybe_warn_too_many_of_same_char([t | _] = token, <<t, _::binary>>, line, column, scope) do
    warning = Toxic.Warning.confusable_repeated_operator(line, column, token, t)
    Toxic.Scope.prepend_warning(warning, scope)
  end

  def maybe_warn_too_many_of_same_char(_token, _rest, _line, _column, scope), do: scope

  def maybe_warn_for_ambiguous_bang_before_equals(
        kind,
        unencoded,
        <<?=, _::binary>>,
        line,
        column,
        scope
      ) do
    identifier =
      case kind do
        :atom -> [?: | unencoded]
        :identifier -> unencoded
      end

    case List.last(identifier) do
      ?! ->
        warning = Toxic.Warning.ambiguous_bang_before_equals(line, column, identifier, kind)
        Toxic.Scope.prepend_warning(warning, scope)

      ?? ->
        warning = Toxic.Warning.ambiguous_question_before_equals(line, column, identifier, kind)
        Toxic.Scope.prepend_warning(warning, scope)

      _ ->
        scope
    end
  end

  def maybe_warn_for_ambiguous_bang_before_equals(
        _kind,
        _unencoded,
        _rest,
        _line,
        _column,
        scope
      ),
      do: scope

  # Inlined from Toxic.Util for cross-module call elimination
  def prev_token({prev, _prev_was_eol, _prev_eol_count}), do: prev

  def previous_was_eol({_prev, true, count}) when is_integer(count) and count > 0, do: count
  def previous_was_eol(_), do: nil

  def previous_was_dot?({{:., _, _}, _, _}), do: true
  def previous_was_dot?(_), do: false

  # Inlined from Toxic.Scope for cross-module call elimination
  defp track_ascii(true, scope), do: scope
  defp track_ascii(false, scope), do: scope(scope, ascii_identifiers_only: false)

  @compile {:inline, prev_token: 1, previous_was_eol: 1, previous_was_dot?: 1, track_ascii: 2}
end
