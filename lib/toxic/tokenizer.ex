defmodule Toxic.Tokenizer do
  import Toxic.CharacterClassifier
  import Toxic.Token
  import Toxic.Operator
  import Toxic.Util
  import Toxic.Scope

  # This cannot happen
  # def tokenize_single([], _line, _column, _scope, _tokens) do
  #   :eof
  # end

  # VC merge conflict

  def tokenize_single([?<, ?<, ?<, ?<, ?<, ?<, ?< | _] = original, line, 1, _scope, _tokens) do
    first_line = Enum.take_while(original, fn c -> c != ?\n and c != ?\r end)

    reason =
      {[line: line, column: 1],
       ~c"found an unexpected version control marker, please resolve the conflicts: ", first_line}

    {:error, reason}
  end

  # Base integers

  def tokenize_single([?0, ?x, h | t], line, column, scope, _tokens) when is_hex(h) do
    {rest, number, original_representation, length} = Toxic.Number.tokenize_hex(t, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  def tokenize_single([?0, ?b, h | t], line, column, scope, _tokens) when is_bin(h) do
    {rest, number, original_representation, length} = Toxic.Number.tokenize_bin(t, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  def tokenize_single([?0, ?o, h | t], line, column, scope, _tokens) when is_octal(h) do
    {rest, number, original_representation, length} = Toxic.Number.tokenize_octal(t, [h], 1)
    token = int(meta(line, column, 2 + length, number), original_representation)
    emit(token, rest, line, column + 2 + length, scope)
  end

  # Comments

  def tokenize_single([?# | string], line, column, scope, tokens) do
    case Toxic.Comment.tokenize_comment(string, [?#]) do
      {:error, char} ->
        # TODO: coverage
        reason =
          {[line: line, column: column],
           ~c"invalid bidirectional formatting character in comment: ", [char]}

        {:error, reason}

      {rest, comment} ->
        preserve_comments(line, column, tokens, comment, rest, scope)

        case tokens do
          [{:eol, _meta} | _] -> reset_eol(rest, line, column, scope)
          _ -> no_token(rest, line, column, scope)
        end
    end
  end

  # Sigils

  def tokenize_single([?~, h | _t] = original, line, column, scope, tokens)
      when is_upcase(h) or is_downcase(h) do
    Toxic.Sigil.tokenize_sigil(original, line, column, scope, tokens)
  end

  # Char tokens

  def tokenize_single([??, ?\\, h | t], line, column, scope, _tokens) do
    char = Toxic.Unescape.unescape_map(h)

    # TODO: warn
    new_scope = scope
    # new_scope = if
    #   H =:= Char, H =/= $\\ ->
    #     case handle_char(Char) of
    #       {Escape, Name} ->
    #         Msg = io_lib:format("found ?\\ followed by code point 0x~.16B (~ts), please use ?~ts instead",
    #                             [Char, Name, Escape]),
    #         prepend_warning(line, column, Msg, scope);

    #       false when ?is_downcase(H); ?is_upcase(H) ->
    #         Msg = io_lib:format("unknown escape sequence ?\\~tc, use ?~tc instead", [H, H]),
    #         prepend_warning(line, column, Msg, scope);

    #       false ->
    #         scope
    #     end;
    #   true ->
    #     scope
    # end,

    # Check if we have a literal newline after the escape
    {token, rest, new_line, new_column} =
      case {h, t} do
        {?\n, _} ->
          # ?\\\n - escaped newline, consume the actual newline
          {char(meta(line, column, line + 1, 1, [??, ?\\, ?\n]), char), t, line + 1, 1}

        _ ->
          # Regular escaped char
          {char(meta(line, column, 3, [??, ?\\, h]), char), t, line, column + 3}
      end

    emit(token, rest, new_line, new_column, new_scope)
  end

  def tokenize_single([??, char | t], line, column, scope, _tokens) do
    # TODO: warn
    new_scope = scope
    # new_scope = case handle_char(Char) of
    #   {Escape, Name} ->
    #     Msg = io_lib:format("found ? followed by code point 0x~.16B (~ts), please use ?~ts instead",
    #                         [Char, Name, Escape]),
    #     prepend_warning(line, column, Msg, scope);
    #   false ->
    #     scope
    # end,

    # Check if the char is a newline
    {token, rest, new_line, new_column} =
      case char do
        ?\n ->
          # ?\n - raw newline character, consume it and move to next line
          {char(meta(line, column, line + 1, 1, [??, ?\n]), char), t, line + 1, 1}

        _ ->
          # Regular char
          {char(meta(line, column, 2, [??, char]), char), t, line, column + 2}
      end

    emit(token, rest, new_line, new_column, new_scope)
  end

  # Heredocs

  def tokenize_single([?", ?", ?" | t], line, column, scope, tokens) do
    Toxic.String.handle_heredocs(t, line, column, ?", scope, tokens)
  end

  def tokenize_single([?', ?', ?' | t], line, column, scope, tokens) do
    # TODO: warn
    new_scope = scope

    # new_scope = prepend_warning(line, column, "single-quoted string represent charlists. Use ~c''' if you indeed want a charlist or use \"\"\" instead"),
    Toxic.String.handle_heredocs(t, line, column, ?', new_scope, tokens)
  end

  # Strings

  def tokenize_single([?" | t], line, column, scope, tokens) do
    Toxic.String.handle_strings(t, line, column + 1, ?", scope, tokens)
  end

  def tokenize_single([?' | t], line, column, scope, tokens) do
    # TODO: warn
    new_scope = scope
    Toxic.String.handle_strings(t, line, column + 1, ?', new_scope, tokens)
  end

  # Operator atoms
  for chars <- ~w(. <<>> %{} % & {} ..//)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1

    def tokenize_single([unquote_splicing(chars), ?: | rest], line, column, scope, _tokens)
        when is_space(hd(rest)) do
      token = kw_identifier(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  for chars <- ~w(<<>> %{} % {} ..//)c do
    atom = List.to_atom(chars)
    length = length(chars) + 1

    def tokenize_single([?:, unquote_splicing(chars) | rest], line, column, scope, _tokens) do
      token = atom(meta(line, column, unquote(length), nil), unquote(atom))
      emit(token, rest, line, column + unquote(length), scope)
    end
  end

  # Three Token Operators
  def tokenize_single([?:, t1, t2, t3 | rest], line, column, scope, _tokens)
      when unary_op3(t1, t2, t3) or comp_op3(t1, t2, t3) or and_op3(t1, t2, t3) or
             or_op3(t1, t2, t3) or
             arrow_op3(t1, t2, t3) or xor_op3(t1, t2, t3) or concat_op3(t1, t2, t3) or
             ellipsis_op3(t1, t2, t3) do
    token = atom(meta(line, column, 4, nil), List.to_atom([t1, t2, t3]))
    emit(token, rest, line, column + 4, scope)
  end

  # Two Token Operators

  def tokenize_single([?:, ?:, ?: | rest], line, column, scope, _tokens) do
    # TODO: warn
    new_scope = scope
    # Message = "atom ::: must be written between quotes, as in :\"::\", to avoid ambiguity",
    # new_scope = prepend_warning(line, column, Message),
    token = atom(meta(line, column, 3, nil), :"::")
    emit(token, rest, line, column + 3, new_scope)
  end

  def tokenize_single([?:, t1, t2 | rest], line, column, scope, _tokens)
      when comp_op2(t1, t2) or rel_op2(t1, t2) or and_op(t1, t2) or or_op(t1, t2) or
             arrow_op(t1, t2) or in_match_op(t1, t2) or concat_op(t1, t2) or power_op(t1, t2) or
             stab_op(t1, t2) or range_op(t1, t2) do
    token = atom(meta(line, column, 3, nil), List.to_atom([t1, t2]))
    emit(token, rest, line, column + 3, scope)
  end

  # Single Token Operators
  def tokenize_single([?:, t | rest], line, column, scope, _tokens)
      when at_op(t) or unary_op(t) or capture_op(t) or dual_op(t) or mult_op(t) or
             rel_op(t) or match_op(t) or pipe_op(t) or t == ?. do
    token = atom(meta(line, column, 2, nil), List.to_atom([t]))
    emit(token, rest, line, column + 2, scope)
  end

  # Stand-alone tokens

  def tokenize_single([?=, ?> | rest], line, column, scope, tokens) do
    token = {:assoc_op, meta(line, column, 2, previous_was_eol(tokens)), :"=>"}
    emit_with_eol(token, rest, line, column + 2, scope)
  end

  # Ternary operator

  def tokenize_single([?., ?., ?/, ?/ | rest] = string, line, column, scope, _tokens) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _] = remaining, extra} ->
        token = {:identifier, meta(line, column, 4, nil), :..//}
        emit(token, remaining, line, column + 4 + extra, scope)

      {_, _} ->
        # TODO: coverage
        reason = {[line: line, column: column], ~c"unexpected token: ", string}
        {:error, reason}
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

    # TODO: warn
    # and_op3 or_op3 xor_op3 concat_op3
    # new_scope = maybe_warn_too_many_of_same_char([t1, t2, t3], rest, line, column, scope),

    def tokenize_single([t1, t2, t3 | rest], line, column, scope, tokens)
        when unquote(token)(t1, t2, t3) do
      unquote(call)(
        rest,
        line,
        column,
        unquote(token_name),
        3,
        List.to_atom([t1, t2, t3]),
        scope,
        tokens
      )
    end
  end

  # Containers + punctuation tokens
  def tokenize_single([?, | rest], line, column, scope, _tokens) do
    token = {:",", meta(line, column, 1, 0)}
    emit(token, rest, line, column + 1, scope)
  end

  def tokenize_single([?<, ?< | rest], line, column, scope, tokens) do
    token = {:"<<", meta(line, column, 2, nil)}
    Toxic.Terminator.handle_terminator(rest, line, column + 2, scope, token, tokens)
  end

  def tokenize_single([?>, ?> | rest], line, column, scope, tokens) do
    token = {:">>", meta(line, column, 2, previous_was_eol(tokens))}
    Toxic.Terminator.handle_terminator(rest, line, column + 2, scope, token, tokens)
  end

  def tokenize_single([?{ | _rest], line, column, _scope, [{:%, _} | _] = _tokens) do
    message =
      ~c"unexpected space between % and {\n\n" ++
        ~c"If you want to define a map, write %{...}, with no spaces.\n" ++
        ~c"If you want to define a struct, write %StructName{...}.\n\n" ++
        ~c"Syntax error before: "

    {:error, {[line: line, column: column], message, [?{]}}
  end

  def tokenize_single([t | rest], line, column, scope, tokens) when t in [?(, ?{, ?[] do
    token = {List.to_atom([t]), meta(line, column, 1, nil)}
    Toxic.Terminator.handle_terminator(rest, line, column + 1, scope, token, tokens)
  end

  def tokenize_single([t | rest], line, column, scope, tokens) when t in [?), ?}, ?]] do
    token = {List.to_atom([t]), meta(line, column, 1, previous_was_eol(tokens))}
    Toxic.Terminator.handle_terminator(rest, line, column + 1, scope, token, tokens)
  end

  # Two Token Operators
  def tokenize_single([t1, t2 | rest], line, column, scope, tokens) when ternary_op(t1, t2) do
    op = List.to_atom([t1, t2])
    token = {:ternary_op, meta(line, column, 2, previous_was_eol(tokens)), op}
    emit_with_eol(token, rest, line, column + 2, scope)
  end

  @two_token_ops ~w(power_op range_op concat_op arrow_op comp_op2 rel_op2 and_op or_op in_match_op type_op stab_op)a

  for token <- @two_token_ops do
    token_name = token |> to_string() |> String.replace_suffix("2", "") |> String.to_atom()

    def tokenize_single([t1, t2 | rest], line, column, scope, tokens)
        when unquote(token)(t1, t2) do
      handle_op(rest, line, column, unquote(token_name), 2, List.to_atom([t1, t2]), scope, tokens)
    end
  end

  # Single Token Operators

  def tokenize_single([?& | rest], line, column, scope, _tokens) do
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

  @single_token_ops ~w(at_op unary_op rel_op dual_op mult_op match_op pipe_op)a
  @unary_single_token_ops ~w(at_op unary_op dual_op)a

  for token <- @single_token_ops do
    call =
      if token in @unary_single_token_ops do
        :handle_unary_op
      else
        :handle_op
      end

    def tokenize_single([t | rest], line, column, scope, tokens) when unquote(token)(t) do
      unquote(call)(rest, line, column, unquote(token), 1, List.to_atom([t]), scope, tokens)
    end
  end

  # Non-operator Atoms

  def tokenize_single(
        [?:, h | t],
        line,
        column,
        base_scope = scope(existing_atoms_only: existing_atoms_only),
        _tokens
      )
      when is_quote(h) do
    scope = base_scope
    # TODO: warn
    # Scope = case H == $' of
    #   true -> prepend_warning(Line, Column, "single quotes around atoms are deprecated. Use double quotes instead", BaseScope);
    #   false -> BaseScope
    # end,
    {kind, start_type} =
      if(existing_atoms_only,
        do: {:atom_safe, :atom_safe_start},
        else: {:atom_unsafe, :atom_unsafe_start}
      )

    start_token = {start_type, meta(line, column, 2, nil), h}
    {{:switch_to_interp, start_token, kind, true, h}, t, line, column + 2, scope}
  end

  def tokenize_single(
        [?: | string] = _original,
        line,
        column,
        scope = scope(cursor_completion: cursor_completion),
        _tokens
      ) do
    case Toxic.Identifier.tokenize_identifier(string, line, column, scope, false) do
      {_kind, unencoded, atom, rest, length, ascii?, _special} ->
        # TODO: warn
        new_scope = scope

        # NewScope = maybe_warn_for_ambiguous_bang_before_equals(atom, Unencoded, Rest, Line, Column, Scope),
        tracked_scope = track_ascii(ascii?, new_scope)
        token = {:atom, meta(line, column, length + 1, unencoded), atom}
        emit(token, rest, line, column + 1 + length, tracked_scope)

      :empty when cursor_completion == false ->
        # TODO: coverage
        {:error, {[line: line, column: column], ~c"unexpected token: ", [?:]}}

      # unexpected_token(Original, Line, Column, Scope, Tokens);
      :empty ->
        # TODO: cursor completion
        no_token([], line, column, scope)

      {:unexpected_token, length} ->
        # TODO: coverage
        bad_part = Enum.drop(string, length - 1)
        {:error, {[line: line, column: column + length - 1], ~c"unexpected token: ", bad_part}}

      {:error, reason} ->
        # TODO: coverage
        {:error, reason}
    end
  end

  # Integers and floats
  def tokenize_single([h | t], line, column, scope, _tokens) when is_digit(h) do
    scope(cursor_completion: cursor_completion) = scope

    case Toxic.Number.tokenize_number(t, [h], 1, false) do
      {:error, reason, original} ->
        {:error, {[line: line, column: column], reason, original}}

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
              _ -> ~c"number"
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

          {:error, {[line: line, column: column], msg, [i]}}
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

  def tokenize_single([t | rest], line, column, scope, tokens) when is_horizontal_space(t) do
    {remaining, stripped} = strip_horizontal_space(rest, 0)
    handle_space_sensitive_tokens(remaining, line, column + 1 + stripped, scope, tokens)
  end

  # End of line

  def tokenize_single([?; | rest], line, column, scope, []) do
    token = {:";", meta(line, column, 1, 0)}
    emit(token, rest, line, column + 1, scope)
  end

  def tokenize_single([?; | rest], line, column, scope, [top | _] = _tokens)
      when elem(top, 0) != :";" do
    token = {:";", meta(line, column, 1, 0)}
    emit(token, rest, line, column + 1, scope)
  end

  def tokenize_single(~c"\\" = _original, line, column, _scope, _tokens) do
    {:error, {[line: line, column: column], ~c"invalid escape \\ at end of file", []}}
  end

  def tokenize_single(~c"\\\n" = _original, line, column, _scope, _tokens) do
    {:error, {[line: line, column: column], ~c"invalid escape \\ at end of file", []}}
  end

  def tokenize_single(~c"\\\r\n" = _original, line, column, _scope, _tokens) do
    {:error, {[line: line, column: column], ~c"invalid escape \\ at end of file", []}}
  end

  def tokenize_single([?\\, ?\n | rest], line, _column, scope, _tokens) do
    tokenize_eol(rest, line, scope, nil)
  end

  def tokenize_single([?\\, ?\r, ?\n | rest], line, _column, scope, _tokens) do
    tokenize_eol(rest, line, scope, nil)
  end

  def tokenize_single([?\n | rest], line, column, scope, tokens) do
    tokenize_eol(rest, line, scope, eol(line, column, tokens))
  end

  def tokenize_single([?\r, ?\n | rest], line, column, scope, tokens) do
    tokenize_eol(rest, line, scope, eol(line, column, tokens))
  end

  # Others

  def tokenize_single([?%, ?( | _rest], line, column, _scope, _tokens) do
    {:error, {[line: line, column: column], ~c"expected %{ to define a map, got: ", [?%, ?(]}}
  end

  def tokenize_single([?%, ?[ | _rest], line, column, _scope, _tokens) do
    {:error, {[line: line, column: column], ~c"expected %{ to define a map, got: ", [?%, ?[]}}
  end

  def tokenize_single(
        [?%, ?{ | t],
        line,
        column,
        scope = scope(elixir_compatibility: elixir_compatibility),
        tokens
      ) do
    # this is a bug in elixir parser but the fix was not accepted
    # https://github.com/elixir-lang/elixir/pull/14741
    # we need a workaround
    token = {:"{", meta(line, if(elixir_compatibility, do: column, else: column + 1), 1, nil)}

    {_, rest, line, column, scope} =
      Toxic.Terminator.handle_terminator(t, line, column + 2, scope, token, [
        {:%{}, meta(line, column, 2, nil)} | tokens
      ])

    {[{:token, {:%{}, meta(line, column - 2, 1, nil)}}, {:token, token}], rest, line, column,
     scope}
  end

  def tokenize_single([?% | t], line, column, scope, _tokens) do
    token = {:%, meta(line, column, 1, nil)}
    emit(token, t, line, column + 1, scope)
  end

  def tokenize_single([?. | t], line, column, scope, tokens) do
    Toxic.Dot.tokenize_dot(t, line, column + 1, meta(line, column, 1, nil), scope, tokens)
  end

  # Identifiers

  def tokenize_single(
        string,
        line,
        column,
        original_scope = scope(cursor_completion: cursor_completion),
        tokens
      ) do
    case Toxic.Identifier.tokenize_identifier(
           string,
           line,
           column,
           original_scope,
           not previous_was_dot?(tokens)
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

            reason =
              {[line: line, column: column],
               ~c"keyword argument must be followed by space after: ", atom_name}

            {:error, reason}

          _ when at? ->
            msg = ~c"invalid character \"@\" (code point U+0040) in " ++ to_charlist(to_string(kind)) ++ ~c": "
            {:error, {[line: line, column: column], msg, Atom.to_charlist(atom)}}

          _ when atom in [:__aliases__, :__block__] ->
            {:error, {[line: line, column: column], ~c"reserved token: ", Atom.to_charlist(atom)}}

          _ when kind == :alias ->
            Toxic.Alias.tokenize_alias(
              rest,
              line,
              column,
              unencoded,
              atom,
              length,
              ascii,
              special,
              scope,
              tokens
            )

          _ when kind == :identifier ->
            # TODO: warn
            new_scope = scope

            # new_scope = maybe_warn_for_ambiguous_bang_before_equals(:identifier, unencoded, rest, line, column, scope)
            token =
              Toxic.Identifier.check_call_identifier(line, column, length, unencoded, atom, rest)

            emit(token, rest, line, column + length, new_scope)

          _ ->
            # TODO: coverage
            {:error, {[line: line, column: column], ~c"unexpected token: ", string}}
        end

      {:keyword, atom, type, rest, length} ->
        Toxic.Keyword.tokenize_keyword(
          type,
          rest,
          line,
          column,
          atom,
          length,
          original_scope,
          tokens
        )

      :empty when cursor_completion == false ->
        {:error, {[line: line, column: column], ~c"unexpected token: ", string}}

      :empty ->
        # TODO: cursor completion
        case string do
          [?~, l] when is_upcase(l) or is_downcase(l) ->
            no_token([], line, column, original_scope)

          [?~] ->
            no_token([], line, column, original_scope)

          _ ->
            # TODO: coverage
            {:error, {[line: line, column: column], ~c"unexpected token: ", string}}
        end

      {:unexpected_token, length} ->
        # TODO: coverage
        bad_part = Enum.drop(string, length - 1)
        {:error, {[line: line, column: column + length - 1], ~c"unexpected token: ", bad_part}}

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

  defp eol(_line, _column, [{token, _meta} | _tokens]) when token in ~w(, ; eol)a do
    :increase_eol
  end

  defp eol(line, column, _tokens) do
    {:eol, meta(line, column, line + 1, 1, 1)}
  end

  defp tokenize_eol(rest, line, scope = scope(column: column), eol) do
    {_stripped_rest, column} = strip_horizontal_space(rest, column)
    indented_scope = scope(scope, indentation: column - 1)

    case eol do
      nil ->
        no_token(rest, line + 1, 1, indented_scope)

      :increase_eol ->
        increase_eol(rest, line + 1, 1, indented_scope)

      eol_token ->
        emit(eol_token, rest, line + 1, 1, indented_scope)
    end
  end

  # Ambiguous unary/binary operators tokens
  # Keywords are not ambiguous operators
  defp handle_space_sensitive_tokens([sign, ?:, space | _] = string, line, column, scope, _tokens)
       when dual_op(sign) and is_space(space) do
    no_token(string, line, column, scope)
  end

  # But everything else, except other operators, are
  defp handle_space_sensitive_tokens([sign, not_marker | t], line, column, scope, [
         {token, _, _} = _h | _tokens
       ])
       when dual_op(sign) and not is_space(not_marker) and not_marker != sign and not_marker != ?/ and
              not_marker != ?> and token in [:identifier, :quoted_identifier_end] do
    rest = [not_marker | t]
    dual_op_token = {:dual_op, meta(line, column, 1, nil), List.to_atom([sign])}
    emit_op_identifier(dual_op_token, rest, line, column + 1, scope)
  end

  # TODO: cursor_completion
  # Handle cursor completion
  # handle_space_sensitive_tokens([], line, column,
  #                               #elixir_tokenizer{cursor_completion=Cursor} = scope,
  #                               [{identifier, Info, Identifier} | tokens]) when Cursor /= false ->
  #   tokenize([$(], line, column+1, scope, [{paren_identifier, Info, Identifier} | tokens]);

  defp handle_space_sensitive_tokens(string, line, column, scope, _tokens) do
    no_token(string, line, column, scope)
  end

  def preserve_comments(
        line,
        column,
        tokens,
        comment,
        rest,
        scope(preserve_comments: preserve_comments)
      )
      when is_function(preserve_comments, 5) do
    preserve_comments.(line, column, tokens, comment, rest)
  end

  def preserve_comments(_line, _column, _tokens, _comment, _rest, _scope) do
    :ok
  end
end
