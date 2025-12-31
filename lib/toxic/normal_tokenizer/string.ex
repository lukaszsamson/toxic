defmodule Toxic.NormalTokenizer.String do
  @moduledoc false
  import Toxic.Token
  import Toxic.CharacterClassifier
  import Toxic.Scope

  def handle_heredocs(t, line, column, h, scope, _lookbehind) do
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

        {{:switch_to_interp, start_token, kind, true, [h, h, h]}, [?\n | headerless], line + 1,
         base_column, scope}

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

        # Message = "heredoc allows only whitespace characters followed by a new line after opening ",
        # error({?LOC(Line, Column + 3), io_lib:format(Message, []), [H, H, H]}, [H, H, H] ++ T, Scope, _Tokens)
    end
  end

  def handle_strings(t, line, column, h, scope, _lookbehind) do
    {start_type, kind} =
      case h do
        ?' -> {:list_string_start, :charlist}
        ?" -> {:bin_string_start, :string}
      end

    start_token = {start_type, meta(line, column - 1, line, column, nil), h}
    {{:switch_to_interp, start_token, kind, true, h}, t, line, column, scope}
  end

  def extract_heredoc_header([?\r, ?\n | rest]), do: {:ok, rest}
  def extract_heredoc_header([?\n | rest]), do: {:ok, rest}

  def extract_heredoc_header([h | t]) when is_horizontal_space(h) do
    extract_heredoc_header(t)
  end

  def extract_heredoc_header(_), do: :error
end
