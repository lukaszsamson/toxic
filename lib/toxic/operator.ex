defmodule Toxic.Operator do
  import Toxic.CharacterClassifier, only: [is_space: 1]
  import Toxic.Token, only: [meta: 4]
  import Toxic.Util
  defguard at_op(t) when t == ?@

  defguard capture_op(t) when t == ?&

  defguard unary_op(t) when t in [?!, ?^]

  defguard range_op(t1, t2) when t1 == ?. and t2 == ?.

  defguard concat_op(t1, t2)
           when (t1 == ?+ and t2 == ?+) or
                  (t1 == ?- and t2 == ?-) or
                  (t1 == ?< and t2 == ?>)

  defguard concat_op3(t1, t2, t3)
           when (t1 == ?+ and t2 == ?+ and t3 == ?+) or
                  (t1 == ?- and t2 == ?- and t3 == ?-)

  defguard power_op(t1, t2) when t1 == ?* and t2 == ?*

  defguard mult_op(t) when t in [?*, ?/]

  defguard dual_op(t) when t in [?+, ?-]

  defguard arrow_op3(t1, t2, t3)
           when (t1 == ?< and t2 == ?< and t3 == ?<) or
                  (t1 == ?> and t2 == ?> and t3 == ?>) or
                  (t1 == ?~ and t2 == ?> and t3 == ?>) or
                  (t1 == ?< and t2 == ?< and t3 == ?~) or
                  (t1 == ?< and t2 == ?~ and t3 == ?>) or
                  (t1 == ?< and t2 == ?| and t3 == ?>)

  defguard arrow_op(t1, t2)
           when (t1 == ?| and t2 == ?>) or
                  (t1 == ?~ and t2 == ?>) or
                  (t1 == ?< and t2 == ?~)

  defguard rel_op(t) when t in [?<, ?>]

  defguard rel_op2(t1, t2)
           when (t1 == ?< and t2 == ?=) or
                  (t1 == ?> and t2 == ?=)

  defguard comp_op2(t1, t2)
           when (t1 == ?= and t2 == ?=) or
                  (t1 == ?= and t2 == ?~) or
                  (t1 == ?! and t2 == ?=)

  defguard comp_op3(t1, t2, t3)
           when (t1 == ?= and t2 == ?= and t3 == ?=) or
                  (t1 == ?! and t2 == ?= and t3 == ?=)

  defguard ternary_op(t1, t2) when t1 == ?/ and t2 == ?/

  defguard and_op(t1, t2) when t1 == ?& and t2 == ?&

  defguard or_op(t1, t2) when t1 == ?| and t2 == ?|

  defguard and_op3(t1, t2, t3) when t1 == ?& and t2 == ?& and t3 == ?&

  defguard or_op3(t1, t2, t3) when t1 == ?| and t2 == ?| and t3 == ?|

  defguard match_op(t) when t == ?=

  defguard in_match_op(t1, t2)
           when (t1 == ?< and t2 == ?-) or
                  (t1 == ?\\ and t2 == ?\\)

  defguard stab_op(t1, t2) when t1 == ?- and t2 == ?>

  defguard type_op(t1, t2) when t1 == ?: and t2 == ?:

  defguard pipe_op(t) when t == ?|

  defguard ellipsis_op3(t1, t2, t3) when t1 == ?. and t2 == ?. and t3 == ?.

  # Deprecated operators

  defguard unary_op3(t1, t2, t3) when t1 == ?~ and t2 == ?~ and t3 == ?~

  defguard xor_op3(t1, t2, t3) when t1 == ?^ and t2 == ?^ and t3 == ?^

  def handle_unary_op([?: | rest], line, column, _kind, length, op, scope, _tokens)
      when is_space(hd(rest)) do
    token = {:kw_identifier, meta(line, column, length + 1, nil), op}
    emit(token, rest, line, column + length + 1, scope)
  end

  def handle_unary_op(rest, line, column, kind, length, op, scope, _tokens) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _] = remaining, extra} ->
        token = {:identifier, meta(line, column, length, nil), op}
        emit(token, remaining, line, column + length + extra, scope)

      {remaining, extra} ->
        token = {kind, meta(line, column, length, nil), op}
        emit(token, remaining, line, column + length + extra, scope)
    end
  end

  def handle_op([?: | rest], line, column, _kind, length, op, scope, _tokens)
      when is_space(hd(rest)) do
    token = {:kw_identifier, meta(line, column, length, nil), op}
    emit(token, rest, line, column + length + 1, scope)
  end

  def handle_op(rest, line, column, kind, length, op, scope, tokens) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _] = remaining, extra} ->
        token = {:identifier, meta(line, column, length, nil), op}
        emit(token, remaining, line, column + length + extra, scope)

      {remaining, extra} ->
        # TODO: warn
        new_scope = scope
        #       NewScope =
        #         %% TODO: Remove these deprecations on Elixir v2.0
        #         case Op of
        #           '^^^' ->
        #             Msg = "^^^ is deprecated. It is typically used as xor but it has the wrong precedence, use Bitwise.bxor/2 instead",
        #             prepend_warning(Line, Column, Msg, Scope);

        #           '~~~' ->
        #             Msg = "~~~ is deprecated. Use Bitwise.bnot/1 instead for clarity",
        #             prepend_warning(Line, Column, Msg, Scope);

        #           '<|>' ->
        #             Msg = "<|> is deprecated. Use another pipe-like operator",
        #             prepend_warning(Line, Column, Msg, Scope);

        #           _ ->
        #             Scope
        #         end,

        token = {kind, meta(line, column, length, previous_was_eol(tokens)), op}
        emit_with_eol(token, remaining, line, column + length + extra, new_scope)
    end
  end
end
