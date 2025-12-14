#!/usr/bin/env elixir

# Benchmark script to compare branches
# Run from the toxic directory

Mix.install([
  {:toxic, path: Path.expand(".", __DIR__)}
])

defmodule BranchBenchmark do
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

    IO.puts("Branch Performance Benchmark")
    IO.puts("============================")
    IO.puts("")

    files = collect_files(limit)
    IO.puts("Files: #{length(files)}")

    total_bytes = Enum.reduce(files, 0, fn f, acc -> acc + byte_size(File.read!(f)) end)
    IO.puts("Total bytes: #{total_bytes}")
    IO.puts("Iterations: #{iterations}")
    IO.puts("")

    # Warmup
    IO.puts("Warming up...")
    _ = benchmark_once(files)
    _ = benchmark_once(files)
    IO.puts("")

    # Run benchmark
    IO.puts("Running benchmark...")
    times =
      for i <- 1..iterations do
        {time, token_count} = benchmark_once(files)
        IO.puts("  Run #{i}: #{Float.round(time / 1000, 2)}ms (#{token_count} tokens)")
        {time, token_count}
      end

    {times_only, _} = Enum.unzip(times)
    {_, token_count} = hd(times)

    avg_time = Enum.sum(times_only) / length(times_only)
    min_time = Enum.min(times_only)
    max_time = Enum.max(times_only)
    std_dev = std_deviation(times_only)

    throughput = token_count / (avg_time / 1_000_000)
    bytes_per_sec = total_bytes / (avg_time / 1_000_000)

    IO.puts("")
    IO.puts("Results:")
    IO.puts("--------")
    IO.puts("  Avg: #{Float.round(avg_time / 1000, 2)}ms")
    IO.puts("  Min: #{Float.round(min_time / 1000, 2)}ms")
    IO.puts("  Max: #{Float.round(max_time / 1000, 2)}ms")
    IO.puts("  Std Dev: #{Float.round(std_dev / 1000, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput, 0)} tokens/sec")
    IO.puts("  Throughput: #{Float.round(bytes_per_sec / 1024, 1)} KB/sec")
    IO.puts("")

    # Output in machine-readable format for comparison
    IO.puts("CSV: #{Float.round(avg_time / 1000, 2)},#{Float.round(min_time / 1000, 2)},#{Float.round(max_time / 1000, 2)},#{Float.round(throughput, 0)}")
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
          IO.puts("Error: projects directory not found")
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

  defp benchmark_once(files) do
    :timer.tc(fn ->
      Enum.reduce(files, 0, fn file, total ->
        content = File.read!(file)
        stream = Toxic.new(content, 1, 1, [])
        {count, _} = count_tokens(stream, 0)
        total + count
      end)
    end)
  end

  defp count_tokens(stream, count) do
    case Toxic.next(stream) do
      {:ok, _token, new_stream} -> count_tokens(new_stream, count + 1)
      {:eof, _} -> {count, stream}
      {:error, _, new_stream} -> count_tokens(new_stream, count + 1)
    end
  end
end

BranchBenchmark.run(System.argv())
