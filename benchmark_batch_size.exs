#!/usr/bin/env elixir

# Benchmark script to test different max_batch values for Toxic tokenizer
# Tests whether batching helps performance or if queue overhead hurts

Mix.install([
  {:toxic, path: Path.expand(".", __DIR__)}
])

defmodule BatchBenchmark do
  @projects_dir "/Users/lukaszsamson/claude_fun/elixir_oss/projects"
  @ignored_dirs ["_build", "deps", ".git", "tmp", "priv", "rel", "cover", "doc", "logs"]

  def run(args \\ []) do
    {parsed, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          project: :string,
          iterations: :integer
        ]
      )

    limit = Keyword.get(parsed, :limit)
    project_filter = Keyword.get(parsed, :project)
    iterations = Keyword.get(parsed, :iterations, 3)

    IO.puts("Toxic Batch Size Benchmark")
    IO.puts("==========================")
    IO.puts("")

    files = collect_files(limit, project_filter)
    IO.puts("Files to benchmark: #{length(files)}")

    # Calculate total bytes
    total_bytes = Enum.reduce(files, 0, fn f, acc -> acc + byte_size(File.read!(f)) end)
    IO.puts("Total bytes: #{total_bytes}")
    IO.puts("Iterations per batch size: #{iterations}")
    IO.puts("")

    # Test different batch sizes
    batch_sizes = [1, 4, 16, 64, 128, 256, 512, 1024, 4096, 16384, 65536, :infinity]

    results =
      Enum.map(batch_sizes, fn batch_size ->
        IO.write("Testing max_batch=#{inspect(batch_size)}...")

        times =
          for _i <- 1..iterations do
            {time, token_count} = benchmark_batch_size(files, batch_size)
            time
          end

        avg_time = Enum.sum(times) / length(times)
        min_time = Enum.min(times)
        max_time = Enum.max(times)

        # Get token count from last run
        {_, token_count} = benchmark_batch_size(files, batch_size)

        throughput = token_count / (avg_time / 1_000_000)
        bytes_per_sec = total_bytes / (avg_time / 1_000_000)

        IO.puts(" avg=#{Float.round(avg_time / 1000, 2)}ms, " <>
                "min=#{Float.round(min_time / 1000, 2)}ms, " <>
                "max=#{Float.round(max_time / 1000, 2)}ms, " <>
                "#{Float.round(throughput, 0)} tok/s")

        %{
          batch_size: batch_size,
          avg_time_us: avg_time,
          min_time_us: min_time,
          max_time_us: max_time,
          tokens: token_count,
          throughput: throughput,
          bytes_per_sec: bytes_per_sec
        }
      end)

    IO.puts("")
    print_results_table(results)
    IO.puts("")
    print_analysis(results)
  end

  defp collect_files(limit, project_filter) do
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

    projects =
      if project_filter do
        Enum.filter(projects, &(Path.basename(&1) == project_filter))
      else
        projects
      end

    files =
      projects
      |> Enum.flat_map(&collect_elixir_files/1)

    if limit do
      Enum.take(files, limit)
    else
      files
    end
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

  defp benchmark_batch_size(files, batch_size) do
    opts =
      if batch_size == :infinity do
        [max_batch: 1_000_000_000]
      else
        [max_batch: batch_size]
      end

    :timer.tc(fn ->
      Enum.reduce(files, 0, fn file, total ->
        content = File.read!(file)
        stream = Toxic.new(content, 1, 1, opts)
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

  defp print_results_table(results) do
    IO.puts("=" |> String.duplicate(90))
    IO.puts("RESULTS TABLE")
    IO.puts("=" |> String.duplicate(90))
    IO.puts("")

    header = String.pad_trailing("Batch Size", 12) <>
             String.pad_leading("Avg (ms)", 12) <>
             String.pad_leading("Min (ms)", 12) <>
             String.pad_leading("Max (ms)", 12) <>
             String.pad_leading("Tokens/sec", 15) <>
             String.pad_leading("KB/sec", 12) <>
             String.pad_leading("Relative", 10)

    IO.puts(header)
    IO.puts("-" |> String.duplicate(90))

    baseline = Enum.find(results, &(&1.batch_size == 256))
    baseline_time = baseline.avg_time_us

    Enum.each(results, fn r ->
      batch_str = if r.batch_size == :infinity, do: "infinity", else: "#{r.batch_size}"
      relative = r.avg_time_us / baseline_time

      row = String.pad_trailing(batch_str, 12) <>
            String.pad_leading("#{Float.round(r.avg_time_us / 1000, 2)}", 12) <>
            String.pad_leading("#{Float.round(r.min_time_us / 1000, 2)}", 12) <>
            String.pad_leading("#{Float.round(r.max_time_us / 1000, 2)}", 12) <>
            String.pad_leading("#{Float.round(r.throughput, 0)}", 15) <>
            String.pad_leading("#{Float.round(r.bytes_per_sec / 1024, 1)}", 12) <>
            String.pad_leading("#{Float.round(relative, 3)}x", 10)

      IO.puts(row)
    end)
  end

  defp print_analysis(results) do
    IO.puts("=" |> String.duplicate(90))
    IO.puts("ANALYSIS")
    IO.puts("=" |> String.duplicate(90))
    IO.puts("")

    # Find fastest
    fastest = Enum.min_by(results, & &1.avg_time_us)
    slowest = Enum.max_by(results, & &1.avg_time_us)
    baseline = Enum.find(results, &(&1.batch_size == 256))

    IO.puts("Fastest: max_batch=#{inspect(fastest.batch_size)} at #{Float.round(fastest.avg_time_us / 1000, 2)}ms")
    IO.puts("Slowest: max_batch=#{inspect(slowest.batch_size)} at #{Float.round(slowest.avg_time_us / 1000, 2)}ms")
    IO.puts("Current default (256): #{Float.round(baseline.avg_time_us / 1000, 2)}ms")
    IO.puts("")

    speedup = baseline.avg_time_us / fastest.avg_time_us
    IO.puts("Potential speedup vs default: #{Float.round(speedup, 3)}x")
    IO.puts("")

    # Check if batching helps at all
    no_batch = Enum.find(results, &(&1.batch_size == 1))
    big_batch = Enum.find(results, &(&1.batch_size == :infinity))

    if no_batch && big_batch do
      IO.puts("Batching effect:")
      IO.puts("  - No batching (max_batch=1): #{Float.round(no_batch.avg_time_us / 1000, 2)}ms")
      IO.puts("  - Large batch (infinity): #{Float.round(big_batch.avg_time_us / 1000, 2)}ms")

      if big_batch.avg_time_us < no_batch.avg_time_us do
        improvement = (no_batch.avg_time_us - big_batch.avg_time_us) / no_batch.avg_time_us * 100
        IO.puts("  - Batching HELPS: #{Float.round(improvement, 1)}% faster with large batches")
      else
        slowdown = (big_batch.avg_time_us - no_batch.avg_time_us) / no_batch.avg_time_us * 100
        IO.puts("  - Batching HURTS: #{Float.round(slowdown, 1)}% slower with large batches")
      end
    end

    IO.puts("")
    IO.puts("Recommendation:")

    cond do
      fastest.batch_size == :infinity or fastest.batch_size >= 4096 ->
        IO.puts("  Consider increasing default max_batch to #{inspect(fastest.batch_size)}")
        IO.puts("  Or remove batching entirely if :infinity is fastest")

      fastest.batch_size <= 64 ->
        IO.puts("  Consider decreasing default max_batch to #{fastest.batch_size}")
        IO.puts("  Queue overhead may be significant")

      fastest.batch_size == 256 ->
        IO.puts("  Current default of 256 appears optimal")

      true ->
        IO.puts("  Consider changing default max_batch to #{fastest.batch_size}")
    end
  end
end

BatchBenchmark.run(System.argv())
