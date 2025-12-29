#!/usr/bin/env elixir

# Benchmark script to compare Toxic backends vs Elixir tokenizer
# Run from the toxic directory: mix run benchmark_backends.exs

defmodule BackendBenchmark do
  @projects_dir "/Users/lukaszsamson/claude_fun/elixir_oss/projects"
  @ignored_dirs ["_build", "deps", ".git", "tmp", "priv", "rel", "cover", "doc", "logs"]

  def run(args \\ []) do
    {parsed, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          iterations: :integer
        ]
      )

    limit = Keyword.get(parsed, :limit)
    iterations = Keyword.get(parsed, :iterations, 5)

    IO.puts("Backend Performance Benchmark")
    IO.puts("=============================")
    IO.puts("")

    files = collect_files(limit)
    IO.puts("Files: #{length(files)}")

    # Pre-read all files into memory
    file_contents = Enum.map(files, &File.read!/1)
    total_bytes = Enum.reduce(file_contents, 0, fn content, acc -> acc + byte_size(content) end)
    IO.puts("Total bytes: #{total_bytes}")
    IO.puts("Iterations: #{iterations}")
    IO.puts("")

    backends = [
      {"Elixir tokenizer", &tokenize_elixir/1},
      {"Toxic charlist", &tokenize_toxic_charlist/1},
      {"Toxic binary", &tokenize_toxic_binary/1}
    ]

    # Warmup
    IO.puts("Warming up...")
    for {_name, tokenizer} <- backends do
      _ = benchmark_once(file_contents, tokenizer)
    end
    IO.puts("")

    # Run benchmarks
    results =
      for {name, tokenizer} <- backends do
        IO.puts("Benchmarking: #{name}")

        times =
          for i <- 1..iterations do
            {time, token_count} = benchmark_once(file_contents, tokenizer)
            IO.puts("  Run #{i}: #{Float.round(time / 1000, 2)}ms (#{token_count} tokens)")
            {time, token_count}
          end

        {times_only, _} = Enum.unzip(times)
        {_, token_count} = hd(times)

        avg_time = Enum.sum(times_only) / length(times_only)
        min_time = Enum.min(times_only)
        max_time = Enum.max(times_only)
        std_dev = std_deviation(times_only)

        IO.puts("")

        {name, %{
          avg: avg_time,
          min: min_time,
          max: max_time,
          std_dev: std_dev,
          token_count: token_count
        }}
      end

    # Print comparison table
    IO.puts("Results Summary")
    IO.puts("===============")
    IO.puts("")

    # Header
    IO.puts(String.pad_trailing("Backend", 20) <>
            String.pad_leading("Avg (ms)", 12) <>
            String.pad_leading("Min (ms)", 12) <>
            String.pad_leading("Max (ms)", 12) <>
            String.pad_leading("Std Dev", 12) <>
            String.pad_leading("Tokens/sec", 15) <>
            String.pad_leading("KB/sec", 12))
    IO.puts(String.duplicate("-", 95))

    # Get baseline (Elixir tokenizer)
    {_, baseline} = Enum.find(results, fn {name, _} -> name == "Elixir tokenizer" end)

    for {name, stats} <- results do
      throughput = stats.token_count / (stats.avg / 1_000_000)
      bytes_per_sec = total_bytes / (stats.avg / 1_000_000)
      speedup = baseline.avg / stats.avg

      row =
        String.pad_trailing(name, 20) <>
        String.pad_leading(format_ms(stats.avg), 12) <>
        String.pad_leading(format_ms(stats.min), 12) <>
        String.pad_leading(format_ms(stats.max), 12) <>
        String.pad_leading(format_ms(stats.std_dev), 12) <>
        String.pad_leading(format_int(throughput), 15) <>
        String.pad_leading(format_kb(bytes_per_sec), 12)

      IO.puts(row)

      if name != "Elixir tokenizer" do
        speedup_str = if speedup > 1, do: "#{Float.round(speedup, 2)}x faster", else: "#{Float.round(1/speedup, 2)}x slower"
        IO.puts(String.pad_trailing("", 20) <> "  vs Elixir: #{speedup_str}")
      end
    end

    IO.puts("")

    # Compare binary vs charlist
    {_, charlist_stats} = Enum.find(results, fn {name, _} -> name == "Toxic charlist" end)
    {_, binary_stats} = Enum.find(results, fn {name, _} -> name == "Toxic binary" end)

    if charlist_stats && binary_stats do
      speedup = charlist_stats.avg / binary_stats.avg
      speedup_str = if speedup > 1, do: "#{Float.round(speedup, 2)}x faster", else: "#{Float.round(1/speedup, 2)}x slower"
      IO.puts("Binary vs Charlist: #{speedup_str}")
    end

    IO.puts("")

    # CSV output
    IO.puts("CSV Output (for spreadsheets):")
    IO.puts("backend,avg_ms,min_ms,max_ms,tokens_per_sec,kb_per_sec")
    for {name, stats} <- results do
      throughput = stats.token_count / (stats.avg / 1_000_000)
      bytes_per_sec = total_bytes / (stats.avg / 1_000_000)
      IO.puts("#{name},#{Float.round(stats.avg / 1000, 2)},#{Float.round(stats.min / 1000, 2)},#{Float.round(stats.max / 1000, 2)},#{round(throughput)},#{Float.round(bytes_per_sec / 1024, 1)}")
    end
  end

  defp format_ms(microseconds) do
    "#{Float.round(microseconds / 1000, 2)}"
  end

  defp format_int(num) do
    num |> round() |> Integer.to_string() |> add_commas()
  end

  defp format_kb(bytes_per_sec) do
    "#{Float.round(bytes_per_sec / 1024, 1)}"
  end

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp std_deviation(values) do
    avg = Enum.sum(values) / length(values)
    variance = Enum.reduce(values, 0, fn v, acc -> acc + (v - avg) * (v - avg) end) / length(values)
    :math.sqrt(variance)
  end

  defp collect_files(limit) do
    projects =
      case File.ls(@projects_dir) do
        {:ok, dirs} ->
          dirs
          |> Enum.filter(&File.dir?(Path.join(@projects_dir, &1)))
          |> Enum.map(&Path.join(@projects_dir, &1))
        {:error, _} ->
          IO.puts("Error: projects directory not found at #{@projects_dir}")
          IO.puts("Please update @projects_dir or create the directory with Elixir projects")
          System.halt(1)
      end

    files =
      projects
      |> Enum.flat_map(&collect_elixir_files/1)

    if limit, do: Enum.take(files, limit), else: files
  end

  defp collect_elixir_files(root_path) do
    Path.wildcard(Path.join(root_path, "**/*.{ex,exs}"))
    |> Enum.reject(&should_ignore_file?/1)
  end

  defp should_ignore_file?(file_path) do
    path_parts = Path.split(file_path)
    phoenix_templates = String.contains?(file_path, "projects/phoenix/installer/templates")
    phoenix_templates or Enum.any?(@ignored_dirs, &(&1 in path_parts))
  end

  defp benchmark_once(file_contents, tokenizer) do
    :timer.tc(fn ->
      Enum.reduce(file_contents, 0, fn content, total ->
        count = tokenizer.(content)
        total + count
      end)
    end)
  end

  # Elixir's built-in tokenizer
  defp tokenize_elixir(content) do
    charlist = String.to_charlist(content)
    case :elixir_tokenizer.tokenize(charlist, 1, 1, []) do
      {:ok, _line, _column, _warnings, tokens} -> length(tokens)
      {:ok, _line, _column, _warnings, tokens, _} -> length(tokens)
      {:error, _, _, _, _} -> 0
      {:error, _, _, _, _, _} -> 0
    end
  end

  # Toxic with charlist backend
  defp tokenize_toxic_charlist(content) do
    stream = Toxic.new(content, 1, 1, lexer_backend: :charlist)
    count_toxic_tokens(stream, 0)
  end

  # Toxic with binary backend
  defp tokenize_toxic_binary(content) do
    stream = Toxic.new(content, 1, 1, lexer_backend: :binary)
    count_toxic_tokens(stream, 0)
  end

  defp count_toxic_tokens(stream, count) do
    case Toxic.next(stream) do
      {:ok, _token, new_stream} -> count_toxic_tokens(new_stream, count + 1)
      {:eof, _} -> count
      {:error, _, new_stream} -> count_toxic_tokens(new_stream, count + 1)
    end
  end
end

BackendBenchmark.run(System.argv())
