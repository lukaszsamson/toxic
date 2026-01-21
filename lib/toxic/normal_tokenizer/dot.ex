defmodule Toxic.NormalTokenizer.Dot do
  @moduledoc false
  import Toxic.Scope
  import Toxic.Util
  import Toxic.NormalTokenizer.Operator
  import Toxic.CharacterClassifier
  import Toxic.Token
  alias Toxic.NormalTokenizer.{Comment, Identifier}

  def tokenize_dot(t, line, column, dot_info, scope = scope(column: scope_column), lookbehind) do
    case strip_horizontal_space(t, 0) do
      {[?# | r], _} ->
        case Comment.tokenize_comment(r, [?#]) do
          {:error, {code, char}}
          when code in [:comment_invalid_bidi, :comment_invalid_linebreak] ->
            token = :io_lib.format("\\u~4.16.0B", [char])

            {:error,
             %Toxic.Error{
               code: code,
               domain: :comment,
               token_display: token,
               details: %{line: line, column: column}
             }}

          {rest, comment} ->
            Comment.preserve_comments(line, column, lookbehind, comment, rest, scope)
            tokenize_dot(rest, line, scope_column, dot_info, scope, lookbehind)
        end

      {[?\r, ?\n | rest], _} ->
        tokenize_dot(rest, line + 1, scope_column, dot_info, scope, lookbehind)

      {[?\n | rest], _} ->
        tokenize_dot(rest, line + 1, scope_column, dot_info, scope, lookbehind)

      {rest, length} ->
        handle_dot([?. | rest], line, column + length, dot_info, scope, lookbehind)
    end
  end

  # Three Token Operators
  defp handle_dot([?., t1, t2, t3 | rest], line, column, dot_info, scope, lookbehind)
       when unary_op3(t1, t2, t3) or comp_op3(t1, t2, t3) or and_op3(t1, t2, t3) or
              or_op3(t1, t2, t3) or
              arrow_op3(t1, t2, t3) or xor_op3(t1, t2, t3) or concat_op3(t1, t2, t3) do
    handle_call_identifier(rest, line, column, dot_info, 3, [t1, t2, t3], scope, lookbehind)
  end

  # Two Token Operators
  defp handle_dot([?., t1, t2 | rest], line, column, dot_info, scope, lookbehind)
       when comp_op2(t1, t2) or rel_op2(t1, t2) or and_op(t1, t2) or or_op(t1, t2) or
              arrow_op(t1, t2) or in_match_op(t1, t2) or concat_op(t1, t2) or power_op(t1, t2) or
              type_op(t1, t2) do
    handle_call_identifier(rest, line, column, dot_info, 2, [t1, t2], scope, lookbehind)
  end

  # Single Token Operators
  defp handle_dot([?., t | rest], line, column, dot_info, scope, lookbehind)
       when at_op(t) or unary_op(t) or capture_op(t) or dual_op(t) or mult_op(t) or
              rel_op(t) or match_op(t) or pipe_op(t) do
    handle_call_identifier(rest, line, column, dot_info, 1, [t], scope, lookbehind)
  end

  # Exception for .( as it needs to be treated specially in the parser
  defp handle_dot([?., ?( | rest], line, column, dot_info, scope, _lookbehind) do
    token = {:dot_call_op, dot_info, :.}
    emit_with_eol(token, [?( | rest], line, column, scope)
  end

  defp handle_dot([?., h | t], line, column, dot_info, base_scope, _lookbehind)
       when is_quote(h) do
    scope =
      if h == ?' do
        warning = Toxic.Warning.deprecated_single_quote_call(line, column)
        Toxic.Scope.prepend_warning(warning, base_scope)
      else
        base_scope
      end

    dot_token = dot_token(dot_info)
    start_tok = {:quoted_identifier_start, meta(line, column, line, 1, nil), h}

    multiple(
      [{:token_with_eol, dot_token}, {:switch_to_interp, start_tok, :quoted_identifier, true, h}],
      t,
      line,
      column + 1,
      scope
    )
  end

  defp handle_dot([?. | rest], line, column, dot_info, scope, _lookbehind) do
    token = dot_token(dot_info)
    emit_with_eol(token, rest, line, column, scope)
  end

  defp handle_call_identifier(
         rest,
         line,
         column,
         dot_info,
         length,
         unencoded_op,
         scope,
         _lookbehind
       ) do
    op_token =
      Identifier.check_call_identifier(
        line,
        column,
        length,
        unencoded_op,
        op_atom_from_unencoded(unencoded_op),
        rest
      )

    dot_token = dot_token(dot_info)

    multiple(
      [{:token_with_eol, dot_token}, {:token, op_token}],
      rest,
      line,
      column + length,
      scope
    )
  end

  defp op_atom_from_unencoded([?@]), do: :@
  defp op_atom_from_unencoded([?!]), do: :!
  defp op_atom_from_unencoded([?^]), do: :^
  defp op_atom_from_unencoded([?&]), do: :&
  defp op_atom_from_unencoded([?+]), do: :+
  defp op_atom_from_unencoded([?-]), do: :-
  defp op_atom_from_unencoded([?*]), do: :*
  defp op_atom_from_unencoded([?/]), do: :/
  defp op_atom_from_unencoded([?<]), do: :<
  defp op_atom_from_unencoded([?>]), do: :>
  defp op_atom_from_unencoded([?=]), do: :=
  defp op_atom_from_unencoded([?|]), do: :|

  defp op_atom_from_unencoded(~c"=="), do: :==
  defp op_atom_from_unencoded(~c"=~"), do: :=~
  defp op_atom_from_unencoded(~c"!="), do: :!=
  defp op_atom_from_unencoded(~c"<="), do: :<=
  defp op_atom_from_unencoded(~c">="), do: :>=
  defp op_atom_from_unencoded(~c"&&"), do: :&&
  defp op_atom_from_unencoded(~c"||"), do: :||
  defp op_atom_from_unencoded(~c"|>"), do: :|>
  defp op_atom_from_unencoded(~c"~>"), do: :~>
  defp op_atom_from_unencoded(~c"<~"), do: :<~
  defp op_atom_from_unencoded(~c"<-"), do: :<-
  defp op_atom_from_unencoded(~c"\\\\"), do: :"\\\\"
  defp op_atom_from_unencoded(~c"++"), do: :++
  defp op_atom_from_unencoded(~c"--"), do: :--
  defp op_atom_from_unencoded(~c"<>"), do: :<>
  defp op_atom_from_unencoded(~c"**"), do: :**
  defp op_atom_from_unencoded(~c"::"), do: :"::"

  defp op_atom_from_unencoded(~c"+++"), do: :+++
  defp op_atom_from_unencoded(~c"---"), do: :---
  defp op_atom_from_unencoded(~c"<<<"), do: :<<<
  defp op_atom_from_unencoded(~c">>>"), do: :>>>
  defp op_atom_from_unencoded(~c"~>>"), do: :~>>
  defp op_atom_from_unencoded(~c"<<~"), do: :<<~
  defp op_atom_from_unencoded(~c"<~>"), do: :<~>
  defp op_atom_from_unencoded(~c"<|>"), do: :"<|>"
  defp op_atom_from_unencoded(~c"==="), do: :===
  defp op_atom_from_unencoded(~c"!=="), do: :!==
  defp op_atom_from_unencoded(~c"&&&"), do: :&&&
  defp op_atom_from_unencoded(~c"|||"), do: :|||
  defp op_atom_from_unencoded(~c"~~~"), do: :"~~~"
  defp op_atom_from_unencoded(~c"^^^"), do: :"^^^"
end
