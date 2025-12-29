defmodule Toxic.BinaryNormalTokenizer.String do
  @moduledoc false
  import Toxic.Token
  import Toxic.CharacterClassifier
  import Toxic.Scope

  def handle_heredocs(t, line, column, h, scope, _tokens) when is_binary(t) do
    # First check if the heredoc header is valid (only whitespace + newline after opening)
    case extract_heredoc_header(t) do
      {:ok, headerless} ->
        {start_type, kind} =
          case h do
            ?' -> {:list_heredoc_start, :list_heredoc}
            ?" -> {:bin_heredoc_start, :bin_heredoc}
          end

        start_token = {start_type, meta(line, column, line, column + 3, nil), [h, h, h]}

        scope(column: base_column) = scope

        # Prepend newline to headerless for compatibility
        {{:switch_to_interp, start_token, kind, true, [h, h, h]}, <<?\n, headerless::binary>>,
         line + 1, base_column, scope}

      :error ->
        err = %Toxic.Error{
          code: :heredoc_invalid_header,
          domain: :heredoc,
          token_display: [h, h, h],
          details: %{
            line: line,
            column: column + 3,
            delim: [h, h, h],
            message_excludes_delim?: true
          }
        }

        {:error, err}
    end
  end

  def handle_strings(t, line, column, h, scope, _tokens) when is_binary(t) do
    {start_type, kind} =
      case h do
        ?' -> {:list_string_start, :charlist}
        ?" -> {:bin_string_start, :string}
      end

    start_token = {start_type, meta(line, column - 1, line, column, nil), h}
    {{:switch_to_interp, start_token, kind, true, h}, t, line, column, scope}
  end

  def extract_heredoc_header(<<?\r, ?\n, rest::binary>>), do: {:ok, rest}
  def extract_heredoc_header(<<?\n, rest::binary>>), do: {:ok, rest}

  def extract_heredoc_header(<<h, rest::binary>>) when is_horizontal_space(h) do
    extract_heredoc_header(rest)
  end

  def extract_heredoc_header(_), do: :error
end
