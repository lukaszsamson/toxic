defmodule Toxic.Driver.Contexts do
  @moduledoc false

  import Toxic.Scope

  alias Toxic.{Driver, Error, Identifier, Scope, Warning}
  alias Toxic.NormalTokenizer.Identifier

  @spec pending_error([Driver.context()], Toxic.Scope.scope()) ::
          {:missing_scope, term()}
          | {:missing_interpolation, term()}
          | {:missing_context, term()}
          | nil
  def pending_error(contexts, scope) do
    cond do
      entry = find_missing_scope_terminator(scope) ->
        {:missing_scope, entry}

      interp = find_missing_interpolation(contexts) ->
        {:missing_interpolation, interp}

      context = find_missing_context(contexts) ->
        {:missing_context, context}

      true ->
        nil
    end
  end

  def pending_error(%Driver{contexts: contexts, scope: scope}) do
    pending_error(contexts, scope)
  end

  @spec mismatched_delimiter_reason({atom(), term(), term()}, atom(), pos_integer(), pos_integer()) ::
          Error.t()
  def mismatched_delimiter_reason({start, meta, _indent}, closing, end_line, end_column) do
    expected = Driver.closing_for(start)
    closing_chars = terminator_chars(closing)

    {{start_line, start_column}, _end_pos, _extra} = meta

    %Error{
      code: :terminator_mismatched_closer,
      domain: :terminator,
      position: {{start_line, start_column}, {end_line, end_column}},
      token_display: closing_chars,
      details: %{
        opening_delimiter: start,
        closing_delimiter: closing,
        expected_delimiter: expected,
        line: start_line,
        column: start_column,
        end_line: end_line,
        end_column: end_column
      }
    }
  end

  def mismatched_delimiter_reason(entry, closing, %Driver{line: end_line, column: end_column}) do
    mismatched_delimiter_reason(entry, closing, end_line, end_column)
  end

  @spec interpolation_in_quoted_identifier_reason(pos_integer(), pos_integer(), term()) ::
          Error.t()
  def interpolation_in_quoted_identifier_reason(start_line, start_column, delim) do
    %Error{
      code: :interpolation_not_allowed_in_quoted_identifier,
      domain: :interpolation,
      token_display: delimiter_charlist(delim),
      details: %{start_line: start_line, start_column: start_column}
    }
  end

  def find_missing_interpolation([:normal, {:interp, _, _, _, _, _, _, _} = interp | _]),
    do: interp

  def find_missing_interpolation([_ | rest]), do: find_missing_interpolation(rest)
  def find_missing_interpolation(_), do: nil

  def find_missing_context([{:interp, _, _, _, _, _, _, _} = interp | _]), do: interp
  def find_missing_context([_ | rest]), do: find_missing_context(rest)
  def find_missing_context(_), do: nil

  defp find_missing_scope_terminator(scope) do
    case scope(scope, :terminators) do
      :none ->
        nil

      [] ->
        nil

      [entry | _] ->
        entry
    end
  end

  @spec missing_terminator_reason(term(), pos_integer(), pos_integer()) :: Error.t()
  def missing_terminator_reason(
        {:interp, kind, _allowed?, delim, _parents,
         %{line: start_line, column: start_column} = start_info, _fragments, _saw_interp},
        end_line,
        end_column
      ) do
    delim_chars = delimiter_charlist(delim)
    opening_atom = delimiter_atom(delim_chars)
    delimiter_length = delimiter_length(delim)

    {resolved_end_line, resolved_end_column} =
      if start_line == end_line do
        {start_line, start_column + delimiter_length}
      else
        {end_line, end_column}
      end

    code =
      if(kind in [:bin_heredoc, :list_heredoc],
        do: :heredoc_missing_terminator,
        else: :string_missing_terminator
      )

    %Error{
      code: code,
      domain: if(code == :heredoc_missing_terminator, do: :heredoc, else: :string),
      token_display: nil,
      details: %{
        opening_delimiter: opening_atom,
        expected_delimiter: opening_atom,
        line: start_line,
        column: start_column,
        end_line: resolved_end_line,
        end_column: resolved_end_column,
        suffix_iolist: context_suffix(kind, delim, start_info)
      }
    }
  end

  def missing_terminator_reason(interp_context, %Driver{line: end_line, column: end_column}) do
    missing_terminator_reason(interp_context, end_line, end_column)
  end

  @spec missing_interpolation_reason(term(), pos_integer(), pos_integer()) :: Error.t()
  def missing_interpolation_reason(
        {:interp, kind, _allowed?, delim, _parents,
         %{line: start_line, column: start_column} = start_info, _fragments, _saw_interp},
        end_line,
        end_column
      ) do
    delim_chars = delimiter_charlist(delim)
    opening_atom = delimiter_atom(delim_chars)
    delimiter_length = delimiter_length(delim)

    {resolved_end_line, resolved_end_column} =
      if start_line == end_line do
        {start_line, start_column + delimiter_length}
      else
        {end_line, end_column}
      end

    %Error{
      code: :interpolation_missing_terminator,
      domain: :interpolation,
      token_display: nil,
      details: %{
        opening_delimiter: opening_atom,
        expected_delimiter: opening_atom,
        start_line: start_line,
        start_column: start_column,
        line: start_line,
        column: start_column,
        end_line: resolved_end_line,
        end_column: resolved_end_column,
        suffix_iolist: context_suffix(kind, delim, start_info)
      }
    }
  end

  def missing_interpolation_reason(interp_context, %Driver{line: end_line, column: end_column}) do
    missing_interpolation_reason(interp_context, end_line, end_column)
  end

  @spec missing_scope_terminator_reason(term(), pos_integer(), pos_integer(), Toxic.Scope.scope()) ::
          Error.t()
  def missing_scope_terminator_reason({start, meta, indent}, end_line, end_column, scope) do
    closing = Driver.closing_for(start)
    hint = missing_scope_hint({start, meta, indent}, closing, scope)

    {{start_line, start_column}, _end_pos, _extra} = meta

    %Error{
      code: :terminator_missing_closer,
      domain: :terminator,
      token_display: nil,
      details: %{
        opening_delimiter: start,
        expected_delimiter: closing,
        line: start_line,
        column: start_column,
        end_line: end_line,
        end_column: end_column,
        hint_iolist: hint
      }
    }
  end

  def missing_scope_terminator_reason(
        entry,
        %Driver{line: end_line, column: end_column, scope: scope}
      ) do
    missing_scope_terminator_reason(entry, end_line, end_column, scope)
  end

  @spec compute_start_info(Driver.token(), term(), pos_integer(), pos_integer()) :: map()
  def compute_start_info(start_token, delimiter, line, column) do
    {_, {{_meta_start_line, _meta_start_column}, {meta_end_line, meta_end_column}, _extra}, _} =
      start_token

    delimiter_length = delimiter_length(delimiter)

    cond do
      line == meta_end_line and column - delimiter_length >= 1 ->
        %{line: meta_end_line, column: column - delimiter_length, token: start_token}

      true ->
        base_column = meta_end_column - delimiter_length
        %{line: meta_end_line, column: base_column, token: start_token}
    end
  end

  def drop_first_interp([{:interp, _, _, _, _, _, _, _} | rest]), do: rest

  def drop_first_normal_before_interp([:normal, {:interp, _, _, _, _, _, _, _} = interp | rest]),
    do: [interp | rest]

  def drop_first_normal_before_interp([head | tail]),
    do: [head | drop_first_normal_before_interp(tail)]

  def context_suffix(:sigil, delim, %{line: line, token: {:sigil_start, _meta, {sigil_atom, _}}}) do
    sigil_name =
      sigil_atom
      |> Atom.to_string()
      |> String.replace_prefix("sigil_", "")
      |> String.to_charlist()

    sigil_label = [?~ | sigil_name]
    delimiter_chars = delimiter_charlist(delim)

    :io_lib.format(~c" (for sigil ~ts~ts starting at line ~B)", [
      sigil_label,
      delimiter_chars,
      line
    ])
  end

  def context_suffix(:quoted_identifier, _delim, %{line: line}) do
    :io_lib.format(~c" (for function name starting at line ~B)", [line])
  end

  def context_suffix(kind, _delim, %{line: line}) when kind in [:atom_safe, :atom_unsafe] do
    :io_lib.format(~c" (for atom starting at line ~B)", [line])
  end

  def context_suffix(kind, _delim, %{line: line}) when kind in [:bin_heredoc, :list_heredoc] do
    :io_lib.format(~c" (for heredoc starting at line ~B)", [line])
  end

  def context_suffix(_, _delim, %{line: line}) do
    :io_lib.format(~c" (for string starting at line ~B)", [line])
  end

  defp missing_scope_hint({_start, _meta, _indent}, _closing, scope(mismatch_hints: [])), do: []

  defp missing_scope_hint({start, _meta, _indent}, closing, scope(mismatch_hints: mismatch_hints)) do
    {^start, hint_meta, _indentation} = :lists.keyfind(start, 1, mismatch_hints)
    {{hint_line, _hint_column}, _, _} = hint_meta

    :io_lib.format(
      ~c"\nhint: it looks like the \"~ts\" on line ~B does not have a matching \"~ts\"",
      [Atom.to_string(start), hint_line, Atom.to_string(closing)]
    )
  end

  @spec maybe_warn_unnecessary_quote(
          atom(),
          binary(),
          term(),
          pos_integer(),
          pos_integer(),
          Scope.scope()
        ) :: Scope.scope()
  def maybe_warn_unnecessary_quote(kind, content, _delim, line, column, scope) do
    warning =
      case kind do
        k when k in [:atom_safe, :atom_unsafe] ->
          Warning.unnecessary_quoted_atom(line, column, content)

        k
        when k in [
               :kw_identifier_safe,
               :kw_identifier_unsafe,
               :kw_identifier_safe_end,
               :kw_identifier_unsafe_end
             ] ->
          Warning.unnecessary_quoted_keyword(line, column, content)

        :quoted_identifier ->
          Warning.unnecessary_quoted_call(line, column, content)
      end

    Scope.prepend_warning(warning, scope)
  end

  def is_unnecessary_quote(_fragments, true, _kind, _scope), do: false

  def is_unnecessary_quote(fragments, false, kind, scope) do
    case fragments do
      [single_fragment] ->
        content = IO.iodata_to_binary(single_fragment)
        check_identifier_validity(content, kind, scope)

      _ ->
        false
    end
  end

  defp check_identifier_validity(content, kind, scope) do
    charlist = String.to_charlist(content)

    case Identifier.tokenize_identifier(charlist, 1, 1, scope, false) do
      {:identifier, ^charlist, _atom, [], _length, true, special} ->
        case kind do
          k when k in [:atom_safe, :atom_unsafe] ->
            if :at in special, do: false, else: {true, content}

          _ ->
            {true, content}
        end

      {:identifier, ^charlist, _atom, [], _length, false, _special} ->
        if kind == :quoted_identifier do
          {true, content}
        else
          false
        end

      _ ->
        false
    end
  end

  defp delimiter_charlist(delim) when is_integer(delim), do: [delim]
  defp delimiter_charlist(delim) when is_list(delim), do: delim

  defp delimiter_atom(chars) do
    chars
    |> List.flatten()
    |> List.to_atom()
  end

  defp delimiter_length(delim) do
    delim
    |> delimiter_charlist()
    |> length()
  end

  defp terminator_chars(delimiter) when is_atom(delimiter) do
    delimiter
    |> Atom.to_string()
    |> String.to_charlist()
  end
end
