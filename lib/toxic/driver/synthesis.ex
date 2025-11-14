defmodule Toxic.Driver.Synthesis do
  @moduledoc false

  import Toxic.Scope
  import Toxic.Token

  alias Toxic.{Driver, Error, Scope}

  @spec synthesize_end_for_kind(atom(), term(), term()) :: Driver.token()
  def synthesize_end_for_kind(:sigil, delim, meta), do: {:sigil_end, meta, delim, 0}
  def synthesize_end_for_kind(:bin_heredoc, delim, meta), do: {:bin_heredoc_end, meta, delim, 0}

  def synthesize_end_for_kind(:list_heredoc, delim, meta),
    do: {:list_heredoc_end, meta, delim, 0}

  def synthesize_end_for_kind(:quoted_identifier, delim, meta),
    do: {:quoted_identifier_end, meta, delim}

  def synthesize_end_for_kind(:charlist, delim, meta), do: {:list_string_end, meta, delim}
  def synthesize_end_for_kind(:string, delim, meta), do: {:bin_string_end, meta, delim}
  def synthesize_end_for_kind(:atom_safe, delim, meta), do: {:atom_safe_end, meta, delim}
  def synthesize_end_for_kind(:atom_unsafe, delim, meta), do: {:atom_unsafe_end, meta, delim}

  @spec synthesize_from_reason(Error.t(), Driver.t()) ::
          {:closer | :opener | :none, [Driver.token()], Scope.scope()}

  def synthesize_from_reason(
        %Error{code: :terminator_mismatched_closer, details: %{expected_delimiter: expected}} =
          _err,
        state
      ) do
    {:ok, tok, new_scope} = synthesize_closing(expected, state)
    tok = maybe_tag_zero_len(tok, state)
    {:closer, [tok], new_scope}
  end

  def synthesize_from_reason(%Error{code: _code, token_display: token_display}, state) do
    flattened_chars = List.flatten(List.wrap(token_display))

    case closer_atom_from_chars(flattened_chars) do
      nil ->
        {:none, [], state.scope}

      closer ->
        case opening_for_closer(closer) do
          nil ->
            {:none, [], state.scope}

          opening ->
            {:ok, tok, new_scope} = synthesize_opening(opening, state)
            tok = maybe_tag_zero_len(tok, state)
            {:opener, [tok], new_scope}
        end
    end
  end

  @spec actual_closer_from_reason(Error.t()) :: atom() | nil
  def actual_closer_from_reason(%Error{} = err) do
    closer_atom_from_chars(List.flatten(List.wrap(err.token_display)))
  end

  defp closer_atom_from_chars(~c")"), do: :")"
  defp closer_atom_from_chars(~c"]"), do: :"]"
  defp closer_atom_from_chars(~c"}"), do: :"}"
  defp closer_atom_from_chars([?>, ?>]), do: :">>"
  defp closer_atom_from_chars(~c"end"), do: :end
  defp closer_atom_from_chars(_), do: nil

  defp opening_for_closer(:")"), do: :"("
  defp opening_for_closer(:"]"), do: :"["
  defp opening_for_closer(:"}"), do: :"{"
  defp opening_for_closer(:">>"), do: :"<<"
  defp opening_for_closer(:end), do: nil

  defp synthesize_closing(closer, state) do
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    token = {closer, meta0}
    scope(terminators: terms) = state.scope

    [_ | rest] = terms
    new_terms = rest

    {:ok, token, scope(state.scope, terminators: new_terms)}
  end

  def synthesize_opening(opening, state) do
    meta0 = meta(state.line, state.column, state.line, state.column, nil)
    token = {opening, meta0}
    scope(indentation: indent, terminators: terms) = state.scope
    new_terms = [{opening, meta0, indent} | terms]

    {:ok, token, scope(state.scope, terminators: new_terms)}
  end

  defp maybe_tag_zero_len({kind, {{sl, sc}, {_el, _ec}, extra}}, _state) do
    {kind, {{sl, sc}, {sl, sc}, extra}}
  end
end
