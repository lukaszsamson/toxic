defmodule Toxic.NormalTokenizer do
  @moduledoc false
  alias Toxic.NormalTokenizer
  alias Toxic.NormalTokenizer.{Identifier, Alias, Number, Dot, Terminator, Sigil, Comment}
  import Toxic.CharacterClassifier
  import Toxic.Token
  import Toxic.NormalTokenizer.Operator

  import Toxic.Util,
    only: [
      strip_horizontal_space: 2,
      no_token: 4,
      reset_eol: 4,
      increase_eol: 4,
      emit: 5,
      emit_with_eol: 5,
      emit_op_identifier: 5
    ]

  import Toxic.Scope, except: [track_ascii: 2]

  # This cannot happen
  # def next([], _line, _column, _scope, _tokens) do
  #   :eof
  # end

  # VC merge conflict

  def next([?<, ?<, ?<, ?<, ?<, ?<, ?< | _] = original, line, 1, _scope, _lookbehind) do
    first_line = Enum.take_while(original, fn c -> c != ?\n and c != ?\r end)

    err = %Toxic.Error{
      code: :vc_merge_conflict_marker,
      domain: :vc,
      token_display: first_line,
      details: %{line: line, column: 1}
    }

    {:error, err}
  end

  # Base integers

  def next([?0, ?x, h | t], line, column, scope, _lookbehind) when is_hex(h) do
    {rest, number, original_representation, length} = Number.tokenize_hex(t, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  def next([?0, ?b, h | t], line, column, scope, _lookbehind) when is_bin(h) do
    {rest, number, original_representation, length} = Number.tokenize_bin(t, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  def next([?0, ?o, h | t], line, column, scope, _lookbehind) when is_octal(h) do
    {rest, number, original_representation, length} = Number.tokenize_octal(t, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  # Comments

  def next([?# | string], line, column, scope, lookbehind) do
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

  def next([?~, h | _t] = original, line, column, scope, lookbehind)
      when is_upcase(h) or is_downcase(h) do
    Sigil.tokenize_sigil(original, line, column, scope, lookbehind)
  end

  # Char tokens

  def next([??, ?\\, h | t], line, column, scope, _lookbehind) do
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

    # Check if we have a literal newline after the escape
    scope(column: base_column) = scope

    {token, rest, new_line, new_column} =
      case {h, t} do
        {?\n, _} ->
          # ?\\\n - escaped newline, consume the actual newline
          {char(meta(line, column, line + 1, base_column, [??, ?\\, ?\n]), char), t, line + 1,
           base_column}

        _ ->
          # Regular escaped char
          {char(meta(line, column, 3, [??, ?\\, h]), char), t, line, column + 3}
      end

    emit(token, rest, new_line, new_column, new_scope)
  end

  def next([??, char | t], line, column, scope, _lookbehind) do
    new_scope =
      case handle_char(char) do
        {escape, name} ->
          warning = Toxic.Warning.unnecessary_char_escape(line, column, char, escape, name)
          Toxic.Scope.prepend_warning(warning, scope)

        false ->
          scope
      end

    # Check if the char is a newline
    scope(column: base_column) = scope

    {token, rest, new_line, new_column} =
      case char do
        ?\n ->
          # ?\n - raw newline character, consume it and move to next line
          {char(meta(line, column, line + 1, base_column, [??, ?\n]), char), t, line + 1,
           base_column}

        _ ->
          # Regular char
          {char(meta(line, column, 2, [??, char]), char), t, line, column + 2}
      end

    emit(token, rest, new_line, new_column, new_scope)
  end

  # Heredocs

  def next([?", ?", ?" | t], line, column, scope, lookbehind) do
    NormalTokenizer.String.handle_heredocs(t, line, column, ?", scope, lookbehind)
  end

  def next([?', ?', ?' | t], line, column, scope, lookbehind) do
    # Note: Charlist deprecation warning will be emitted in the driver
    NormalTokenizer.String.handle_heredocs(t, line, column, ?', scope, lookbehind)
  end

  # Strings

  def next([?" | t], line, column, scope, lookbehind) do
    NormalTokenizer.String.handle_strings(t, line, column + 1, ?", scope, lookbehind)
  end

  def next([?' | t], line, column, scope, lookbehind) do
    # Note: Don't emit charlist deprecation warning here yet
    # It will be emitted in the driver after we know if this is a keyword identifier or not
    NormalTokenizer.String.handle_strings(t, line, column + 1, ?', scope, lookbehind)
  end

  # Operator atoms
  for chars <- ~w(. <<>> %{} % & {} ..//)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1

    def next([unquote_splicing(chars), ?: | rest], line, column, scope, _lookbehind)
        when is_space(hd(rest)) do
      token = kw_identifier(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  for chars <- ~w(<<>> %{} % {} ..//)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1

    def next([?:, unquote_splicing(chars) | rest], line, column, scope, _lookbehind) do
      token = atom(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  # Three Token Operator Atoms
  for chars <- ~w(+++ --- <<< >>> ~>> <<~ <~> <|> === !== &&& ||| ... ~~~ ^^^)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1

    def next([?:, unquote_splicing(chars) | rest], line, column, scope, _lookbehind) do
      token = atom(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  # Two Token Operators

  def next([?:, ?:, ?: | rest], line, column, scope, _lookbehind) do
    warning = Toxic.Warning.ambiguous_triple_colon_atom(line, column)
    new_scope = Toxic.Scope.prepend_warning(warning, scope)
    token = atom(meta(line, column, 3, nil), :"::")
    emit(token, rest, line, column + 3, new_scope)
  end

  for chars <-
        [
          ~c"==",
          ~c"=~",
          ~c"!=",
          ~c"<=",
          ~c">=",
          ~c"&&",
          ~c"||",
          ~c"|>",
          ~c"~>",
          ~c"<~",
          ~c"<-",
          ~c"++",
          ~c"--",
          ~c"<>",
          ~c"**",
          ~c"->",
          ~c"..",
          ~c"\\\\"
        ] do
    op = List.to_atom(chars)
    length = length(chars) + 1

    def next([?:, unquote_splicing(chars) | rest], line, column, scope, _lookbehind) do
      token = atom(meta(line, column, unquote(length), nil), unquote(op))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  # Single Token Operator Atoms
  for {char, op} <- [
        {?@, :@},
        {?!, :!},
        {?^, :^},
        {?&, :&},
        {?+, :+},
        {?-, :-},
        {?*, :*},
        {?/, :/},
        {?<, :<},
        {?>, :>},
        {?=, :=},
        {?|, :|},
        {?., :.}
      ] do
    def next([?:, unquote(char) | rest], line, column, scope, _lookbehind) do
      token = atom(meta(line, column, 2, nil), unquote(op))
      emit(token, rest, line, column + 2, scope)
    end
  end

  # Stand-alone tokens

  def next([?=, ?> | rest], line, column, scope, lookbehind) do
    token = {:assoc_op, meta(line, column, 2, previous_was_eol(lookbehind)), :"=>"}
    emit_with_eol(token, rest, line, column + 2, scope)
  end

  # Ternary operator

  def next([?., ?., ?/, ?/ | rest] = string, line, column, scope, _lookbehind) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _] = remaining, extra} ->
        token = {:identifier, meta(line, column, 4, nil), :..//}
        emit(token, remaining, line, column + 4 + extra, scope)

      {_, _} ->
        {:error, unexpected_token_reason(hd(string), line, column)}
    end
  end

  # Three token operators
  for chars <- ~w(~~~)c do
    op = List.to_atom(chars)

    def next([unquote_splicing(chars) | rest], line, column, scope, lookbehind) do
      new_scope =
        maybe_warn_too_many_of_same_char(unquote(chars), rest, line, column, scope)

      handle_unary_op(rest, line, column, :unary_op, 3, unquote(op), new_scope, lookbehind)
    end
  end

  for chars <- ~w(...)c do
    op = List.to_atom(chars)

    def next([unquote_splicing(chars) | rest], line, column, scope, lookbehind) do
      new_scope =
        maybe_warn_too_many_of_same_char(unquote(chars), rest, line, column, scope)

      handle_unary_op(rest, line, column, :ellipsis_op, 3, unquote(op), new_scope, lookbehind)
    end
  end

  for chars <- ~w(+++ --- <<< >>> ~>> <<~ <~> <|> === !== &&& ||| ^^^)c do
    op = List.to_atom(chars)

    kind =
      case chars do
        ~c"+++" -> :concat_op
        ~c"---" -> :concat_op
        ~c"<<<" -> :arrow_op
        ~c">>>" -> :arrow_op
        ~c"~>>" -> :arrow_op
        ~c"<<~" -> :arrow_op
        ~c"<~>" -> :arrow_op
        ~c"<|>" -> :arrow_op
        ~c"===" -> :comp_op
        ~c"!==" -> :comp_op
        ~c"&&&" -> :and_op
        ~c"|||" -> :or_op
        ~c"^^^" -> :xor_op
      end

    def next([unquote_splicing(chars) | rest], line, column, scope, lookbehind) do
      new_scope =
        maybe_warn_too_many_of_same_char(unquote(chars), rest, line, column, scope)

      handle_op(rest, line, column, unquote(kind), 3, unquote(op), new_scope, lookbehind)
    end
  end

  # Containers + punctuation tokens
  def next([?, | rest], line, column, scope, _lookbehind) do
    token = comma(meta(line, column, 1, 0))
    emit(token, rest, line, column + 1, scope)
  end

  def next([?<, ?< | rest], line, column, scope, lookbehind) do
    token = open_bitstring(meta(line, column, 2, nil))
    Terminator.handle_terminator(rest, line, column + 2, scope, token, lookbehind)
  end

  def next([?>, ?> | rest], line, column, scope, lookbehind) do
    token = close_bitstring(meta(line, column, 2, previous_was_eol(lookbehind)))
    Terminator.handle_terminator(rest, line, column + 2, scope, token, lookbehind)
  end

  def next([?{ | _rest], line, column, _scope, {{:%, _, _}, _, _}) do
    err = %Toxic.Error{
      code: :map_unexpected_space_after_percent,
      domain: :map,
      token_display: [?{],
      position: {{line, column}, {line, column + 1}},
      details: %{line: line, column: column}
    }

    {:error, err}
  end

  def next([t | rest], line, column, scope, lookbehind) when t in [?(, ?{, ?[] do
    token =
      case t do
        ?( -> token(:"(", meta(line, column, 1, nil), nil)
        ?{ -> token(:"{", meta(line, column, 1, nil), nil)
        ?[ -> token(:"[", meta(line, column, 1, nil), nil)
      end

    Terminator.handle_terminator(rest, line, column + 1, scope, token, lookbehind)
  end

  def next([t | rest], line, column, scope, lookbehind) when t in [?), ?}, ?]] do
    token =
      case t do
        ?) -> token(:")", meta(line, column, 1, previous_was_eol(lookbehind)), nil)
        ?} -> token(:"}", meta(line, column, 1, previous_was_eol(lookbehind)), nil)
        ?] -> token(:"]", meta(line, column, 1, previous_was_eol(lookbehind)), nil)
      end

    Terminator.handle_terminator(rest, line, column + 1, scope, token, lookbehind)
  end

  # Two Token Operators
  def next([t1, t2 | rest], line, column, scope, lookbehind) when ternary_op(t1, t2) do
    op = :"//"
    token = {:ternary_op, meta(line, column, 2, previous_was_eol(lookbehind)), op}
    emit_with_eol(token, rest, line, column + 2, scope)
  end

  for {chars, kind} <- [
        {~c"**", :power_op},
        {~c"..", :range_op},
        {~c"++", :concat_op},
        {~c"--", :concat_op},
        {~c"<>", :concat_op},
        {~c"|>", :arrow_op},
        {~c"~>", :arrow_op},
        {~c"<~", :arrow_op},
        {~c"==", :comp_op},
        {~c"=~", :comp_op},
        {~c"!=", :comp_op},
        {~c"<=", :rel_op},
        {~c">=", :rel_op},
        {~c"&&", :and_op},
        {~c"||", :or_op},
        {~c"<-", :in_match_op},
        {~c"\\\\", :in_match_op},
        {~c"::", :type_op},
        {~c"->", :stab_op}
      ] do
    op = List.to_atom(chars)

    def next([unquote_splicing(chars) | rest], line, column, scope, lookbehind) do
      handle_op(rest, line, column, unquote(kind), 2, unquote(op), scope, lookbehind)
    end
  end

  # Single Token Operators

  def next([?& | rest], line, column, scope, _lookbehind) do
    kind =
      case strip_horizontal_space(rest, 0) do
        {[int | _], 0} when is_digit(int) ->
          :capture_int

        {[?/ | new_rest], _} ->
          case strip_horizontal_space(new_rest, 0) do
            {[?/ | _], _} -> :capture_op
            {_, _} -> :identifier
          end

        {_, _} ->
          :capture_op
      end

    token = {kind, meta(line, column, 1, nil), :&}
    emit(token, rest, line, column + 1, scope)
  end

  @unary_single_token_ops ~w(at_op unary_op dual_op)a

  for {char, kind, op} <- [
        {?@, :at_op, :@},
        {?!, :unary_op, :!},
        {?^, :unary_op, :^},
        {?+, :dual_op, :+},
        {?-, :dual_op, :-},
        {?<, :rel_op, :<},
        {?>, :rel_op, :>},
        {?*, :mult_op, :*},
        {?/, :mult_op, :/},
        {?=, :match_op, :=},
        {?|, :pipe_op, :|}
      ] do
    if kind in @unary_single_token_ops do
      def next([unquote(char) | rest], line, column, scope, lookbehind) do
        handle_unary_op(rest, line, column, unquote(kind), 1, unquote(op), scope, lookbehind)
      end
    else
      def next([unquote(char) | rest], line, column, scope, lookbehind) do
        handle_op(rest, line, column, unquote(kind), 1, unquote(op), scope, lookbehind)
      end
    end
  end

  # Non-operator Atoms

  def next(
        [?:, h | t],
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
    {{:switch_to_interp, start_token, kind, true, h}, t, line, column + 2, scope}
  end

  def next(
        [?: | string] = _original,
        line,
        column,
        scope = scope(cursor_completion: cursor_completion),
        _lookbehind
      ) do
    case Identifier.tokenize_identifier(string, line, column, scope, false) do
      {_kind, unencoded, atom, rest, length, ascii?, _special} ->
        new_scope =
          maybe_warn_for_ambiguous_bang_before_equals(:atom, unencoded, rest, line, column, scope)

        tracked_scope = track_ascii(ascii?, new_scope)
        token = {:atom, meta(line, column, length + 1, unencoded), atom}
        emit(token, rest, line, column + 1 + length, tracked_scope)

      :empty when cursor_completion == false ->
        {:error, unexpected_token_reason(?:, line, column)}

      # unexpected_token(Original, Line, Column, Scope, Tokens);
      :empty ->
        # TODO: cursor completion
        no_token([], line, column, scope)

      {:unexpected_token, length} ->
        [bad | _] = Enum.drop(string, length - 1)
        reason = unexpected_token_reason(bad, line, column + length - 1)

        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Integers and floats
  def next([h | t], line, column, scope, _lookbehind) when is_digit(h) do
    scope(cursor_completion: cursor_completion) = scope

    case Number.tokenize_number(t, [h], 1, false) do
      {:error, reason, original} ->
        err = %Toxic.Error{
          code: :number_invalid_float,
          domain: :number,
          token_display: original,
          details: %{line: line, column: column, reason_iolist: reason}
        }

        {:error, err}

      {[i | rest], number, _original, _length} when is_upcase(i) or is_downcase(i) or i == ?_ ->
        if number == 0 and i in [?x, ?0, ?b] and rest == [] and cursor_completion != false do
          # tokenize([], line, column, scope, tokens)
          # TODO: cursor completion
          no_token([], line, column, scope)
        else
          # Msg =
          #   io_lib:format(
          #     "invalid character \"~ts\" after number ~ts. If you intended to write a number, "
          #     "make sure to separate the number from the character (using comma, space, etc). "
          #     "If you meant to write a function name or a variable, note that identifiers in "
          #     "Elixir cannot start with numbers. Unexpected token: ",
          #     [[I], original]
          #   ),

          # Convert to charlist for consistency with Elixir
          char_str = to_charlist(<<i::utf8>>)
          # Use original to get the number part that was parsed
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

      {rest, number, original, length} when is_integer(number) ->
        token = int(meta(line, column, length, number), original)
        emit(token, rest, line, column + length, scope)

      {rest, number, original, length} ->
        token = flt(meta(line, column, length, number), original)
        emit(token, rest, line, column + length, scope)
    end
  end

  # Spaces

  def next([t | rest], line, column, scope, lookbehind) when is_horizontal_space(t) do
    {remaining, stripped} = strip_horizontal_space(rest, 0)
    handle_space_sensitive_tokens(remaining, line, column + 1 + stripped, scope, lookbehind)
  end

  # End of line

  # Consecutive semicolons - emit error
  def next([?; | _rest], line, column, _scope, {{:";", _, _}, _, _}) do
    # Match Elixir's token format: ";" (column N, code point U+003B)
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

  def next([?; | rest], line, column, scope, _lookbehind) do
    token = semicolon(meta(line, column, 1, 0))
    emit(token, rest, line, column + 1, scope)
  end

  def next(~c"\\" = _original, line, column, _scope, _lookbehind) do
    {:error,
     %Toxic.Error{
       code: :string_missing_terminator,
       domain: :string,
       token_display: [],
       details: %{line: line, column: column, escape_at_eof?: true}
     }}
  end

  def next(~c"\\\n" = _original, line, column, _scope, _lookbehind) do
    {:error,
     %Toxic.Error{
       code: :string_missing_terminator,
       domain: :string,
       token_display: [],
       details: %{line: line, column: column, escape_at_eof?: true}
     }}
  end

  def next(~c"\\\r\n" = _original, line, column, _scope, _lookbehind) do
    {:error,
     %Toxic.Error{
       code: :string_missing_terminator,
       domain: :string,
       token_display: [],
       details: %{line: line, column: column, escape_at_eof?: true}
     }}
  end

  def next([?\\, ?\n | rest], line, _column, scope, _lookbehind) do
    tokenize_eol(rest, line, scope, nil)
  end

  def next([?\\, ?\r, ?\n | rest], line, _column, scope, _lookbehind) do
    tokenize_eol(rest, line, scope, nil)
  end

  def next([?\n | rest], line, column, scope, lookbehind) do
    tokenize_eol(rest, line, scope, eol(line, column, scope, lookbehind))
  end

  def next([?\r, ?\n | rest], line, column, scope, lookbehind) do
    tokenize_eol(rest, line, scope, eol(line, column, scope, lookbehind))
  end

  # Others

  def next([?%, ?( | _rest], line, column, _scope, _lookbehind) do
    err = %Toxic.Error{
      code: :map_invalid_open_delimiter,
      domain: :map,
      token_display: [?%, ?(],
      details: %{line: line, column: column}
    }

    {:error, err}
  end

  def next([?%, ?[ | _rest], line, column, _scope, _lookbehind) do
    err = %Toxic.Error{
      code: :map_invalid_open_delimiter,
      domain: :map,
      token_display: [?%, ?[],
      details: %{line: line, column: column}
    }

    {:error, err}
  end

  def next(
        [?%, ?{ | t],
        line,
        column,
        scope = scope(elixir_compatibility: elixir_compatibility),
        lookbehind
      ) do
    # this is a bug in elixir parser but the fix was not accepted
    # https://github.com/elixir-lang/elixir/pull/14741
    # we need a workaround
    token =
      token(
        :"{",
        meta(line, if(elixir_compatibility, do: column, else: column + 1), 1, nil),
        nil
      )

    {_, rest, line, column, scope} =
      Terminator.handle_terminator(
        t,
        line,
        column + 2,
        scope,
        token,
        lookbehind
      )

    {[
       {:token, token(:%{}, meta(line, column - 2, 1, nil), nil)},
       {:token, token}
     ], rest, line, column, scope}
  end

  def next([?% | t], line, column, scope, _lookbehind) do
    token = token(:%, meta(line, column, 1, nil), nil)
    emit(token, t, line, column + 1, scope)
  end

  def next([?. | t], line, column, scope, lookbehind) do
    Dot.tokenize_dot(t, line, column + 1, meta(line, column, 1, nil), scope, lookbehind)
  end

  # Identifiers

  def next(
        string,
        line,
        column,
        original_scope = scope(cursor_completion: cursor_completion),
        lookbehind
      ) do
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
          [?: | t] when is_space(hd(t)) ->
            token = {:kw_identifier, meta(line, column, length + 1, unencoded), atom}
            emit(token, t, line, column + length + 1, scope)

          [?: | t] when hd(t) != ?: ->
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
            {:error, unexpected_token_reason(hd(string), line, column)}
        end

      {:keyword, atom, type, rest, length} ->
        NormalTokenizer.Keyword.tokenize_keyword(
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
        {:error, unexpected_token_reason(hd(string), line, column)}

      :empty ->
        # TODO: cursor completion
        case string do
          [?~, l] when is_upcase(l) or is_downcase(l) ->
            no_token([], line, column, original_scope)

          [?~] ->
            no_token([], line, column, original_scope)

          _ ->
            {:error, unexpected_token_reason(hd(string), line, column)}
        end

      {:unexpected_token, length} ->
        [bad | _] = Enum.drop(string, length - 1)
        reason = unexpected_token_reason(bad, line, column + length - 1)

        {:error, reason}

      # unexpected_token(
      #   Enum.drop(string, length - 1),
      #   line,
      #   column + length - 1,
      #   original_scope,
      #   tokens
      # )

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
  # probably not needed
  defp handle_char(?\s), do: {~c"\\s", ~c"space"}
  # probably not needed
  defp handle_char(?\t), do: {~c"\\t", ~c"tab"}
  defp handle_char(?\v), do: {~c"\\v", ~c"vertical tab"}
  defp handle_char(_), do: false

  defp eol(_line, _column, _scope, {{token, _meta, _}, _, _})
       when token in ~w(, ; eol)a do
    :increase_eol
  end

  defp eol(line, column, scope, _lookbehind) do
    scope(column: base_column) = scope
    {:eol, meta(line, column, line + 1, base_column, 1), nil}
  end

  defp tokenize_eol(rest, line, scope = scope(column: base_column), eol) do
    {stripped_rest, column} = strip_horizontal_space(rest, base_column)
    indented_scope = scope(scope, indentation: column - 1)

    case eol do
      nil ->
        no_token(stripped_rest, line + 1, column, indented_scope)

      :increase_eol ->
        increase_eol(stripped_rest, line + 1, column, indented_scope)

      eol_token ->
        emit(eol_token, stripped_rest, line + 1, column, indented_scope)
    end
  end

  # Ambiguous unary/binary operators tokens
  # Keywords are not ambiguous operators
  defp handle_space_sensitive_tokens(
         [sign, ?:, space | _] = string,
         line,
         column,
         scope,
         _lookbehind
       )
       when dual_op(sign) and is_space(space) do
    no_token(string, line, column, scope)
  end

  # But everything else, except other operators, are
  defp handle_space_sensitive_tokens(
         [sign, not_marker | t],
         line,
         column,
         scope,
         {{token, _, _}, _, _}
       )
       when dual_op(sign) and not is_space(not_marker) and not_marker != sign and not_marker != ?/ and
              not_marker != ?> and token in [:identifier, :quoted_identifier_end] do
    rest = [not_marker | t]

    dual_op_atom =
      case sign do
        ?+ -> :+
        _ -> :-
      end

    dual_op_token = {:dual_op, meta(line, column, 1, nil), dual_op_atom}
    emit_op_identifier(dual_op_token, rest, line, column + 1, scope)
  end

  # TODO: cursor_completion
  # Handle cursor completion
  # handle_space_sensitive_tokens([], line, column,
  #                               #elixir_tokenizer{cursor_completion=Cursor} = scope,
  #                               [{identifier, Info, Identifier} | tokens]) when Cursor /= false ->
  #   tokenize([$(], line, column+1, scope, [{paren_identifier, Info, Identifier} | tokens]);

  defp handle_space_sensitive_tokens(string, line, column, scope, _lookbehind) do
    no_token(string, line, column, scope)
  end

  # Warning helper functions

  @doc """
  Warns if three identical characters are followed by another of the same character.
  Used to catch potentially confusing patterns like `&&&&` or `||||`.
  """
  def maybe_warn_too_many_of_same_char([t | _] = token, [t | _], line, column, scope) do
    warning = Toxic.Warning.confusable_repeated_operator(line, column, token, t)
    Toxic.Scope.prepend_warning(warning, scope)
  end

  def maybe_warn_too_many_of_same_char(_token, _rest, _line, _column, scope), do: scope

  @doc """
  Warns about ambiguous bang-before-equals patterns like `foo!=` which could be
  confused with `foo !=`.
  """
  def maybe_warn_for_ambiguous_bang_before_equals(kind, unencoded, [?= | _], line, column, scope) do
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
