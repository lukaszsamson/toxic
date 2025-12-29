#!/usr/bin/env elixir

# Profiling script for Toxic tokenizer on real-world Elixir code
# Usage examples:
#   mix run profile_toxic.exs --type time
#   mix run profile_toxic.exs --type memory
#   mix run profile_toxic.exs --type calls
#   mix run profile_toxic.exs --type time --matching Toxic.Driver
#   mix run profile_toxic.exs --type time --project phoenix
#   mix run profile_toxic.exs --type time --limit 100
#   mix run profile_toxic.exs --backend binary --type time
#
# Profiler selection:
#   mix run profile_toxic.exs --profiler fprof              # use fprof (detailed caller/callee)
#   mix run profile_toxic.exs --profiler fprof --callers    # show caller/callee relationships
#   mix run profile_toxic.exs --profiler fprof --details    # per-process breakdown
#   mix run profile_toxic.exs --profiler fprof --sort own   # sort by own time (not accumulated)
#   mix run profile_toxic.exs --profiler eprof              # force eprof
#   mix run profile_toxic.exs --profiler cprof              # force cprof (calls only)

# Note: When running inside a Mix project, use `mix run profile_toxic.exs`
# When running standalone, uncomment the Mix.install line below:
# Mix.install([{:toxic, path: Path.expand(".", __DIR__)}])

defmodule ToxicProfiler do
  @moduledoc """
  Profiles Toxic tokenizer on real-world Elixir code corpus.
  """

  @projects_dir "/Users/lukaszsamson/claude_fun/elixir_oss/projects"
  @ignored_dirs ["_build", "deps", ".git", "tmp", "priv", "rel", "cover", "doc", "logs"]
  @ignored_files ["mix.lock"]

  def run(args \\ []) do
    opts = parse_args(args)

    IO.puts("Toxic Tokenizer Profiler")
    IO.puts("========================")
    IO.puts("Backend: #{opts.backend}")
    IO.puts("Profiler: #{opts.profiler}")
    IO.puts("Profile type: #{opts.type}")
    IO.puts("Matching: #{format_matching(opts.matching)}")
    if opts.project, do: IO.puts("Project filter: #{opts.project}")
    if opts.limit, do: IO.puts("File limit: #{opts.limit}")
    if opts.profiler == :fprof do
      if opts.callers, do: IO.puts("fprof: --callers enabled")
      if opts.details, do: IO.puts("fprof: --details enabled")
      if opts.trace_to_file, do: IO.puts("fprof: --trace-to-file enabled")
    end
    IO.puts("")

    files = collect_files(opts)
    IO.puts("Collected #{length(files)} files to profile")
    IO.puts("")

    if length(files) == 0 do
      IO.puts("No files found. Exiting.")
      System.halt(1)
    end

    # Pre-warmup: ensure all code is loaded
    IO.puts("Loading code...")
    _ = tokenize_file(hd(files), opts.backend)

    # Run the profiler
    run_profile(files, opts)
  end

  defp parse_args(args) do
    {parsed, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          type: :string,
          profiler: :string,
          matching: :string,
          project: :string,
          limit: :integer,
          no_warmup: :boolean,
          sort: :string,
          backend: :string,
          # fprof-specific options
          callers: :boolean,
          details: :boolean,
          trace_to_file: :boolean
        ]
      )

    %{
      type: parse_type(Keyword.get(parsed, :type, "time")),
      profiler: parse_profiler(Keyword.get(parsed, :profiler)),
      matching: parse_matching(Keyword.get(parsed, :matching)),
      project: Keyword.get(parsed, :project),
      limit: Keyword.get(parsed, :limit),
      warmup: not Keyword.get(parsed, :no_warmup, false),
      sort: parse_sort(Keyword.get(parsed, :sort)),
      backend: parse_backend(Keyword.get(parsed, :backend, "charlist")),
      # fprof options
      callers: Keyword.get(parsed, :callers, false),
      details: Keyword.get(parsed, :details, false),
      trace_to_file: Keyword.get(parsed, :trace_to_file, false)
    }
  end

  defp parse_backend("charlist"), do: :charlist
  defp parse_backend("binary"), do: :binary
  defp parse_backend(other), do: raise("Invalid backend: #{other}. Use: charlist, binary")

  defp parse_type("time"), do: :time
  defp parse_type("memory"), do: :memory
  defp parse_type("calls"), do: :calls
  defp parse_type(other), do: raise("Invalid type: #{other}. Use: time, memory, calls")

  defp parse_profiler(nil), do: :auto
  defp parse_profiler("auto"), do: :auto
  defp parse_profiler("tprof"), do: :tprof
  defp parse_profiler("eprof"), do: :eprof
  defp parse_profiler("cprof"), do: :cprof
  defp parse_profiler("fprof"), do: :fprof
  defp parse_profiler(other), do: raise("Invalid profiler: #{other}. Use: auto, tprof, eprof, cprof, fprof")

  defp parse_sort(nil), do: nil
  defp parse_sort("time"), do: :time
  defp parse_sort("calls"), do: :calls
  defp parse_sort("memory"), do: :memory
  defp parse_sort("per_call"), do: :per_call
  # fprof-specific sort options
  defp parse_sort("acc"), do: :acc
  defp parse_sort("own"), do: :own
  defp parse_sort(other), do: raise("Invalid sort: #{other}")

  defp parse_matching(nil), do: {:_, :_, :_}

  defp parse_matching(str) do
    case String.split(str, ".") do
      [mod] ->
        {String.to_atom("Elixir." <> mod), :_, :_}

      [mod, func] ->
        {String.to_atom("Elixir." <> mod), String.to_atom(func), :_}

      _ ->
        raise "Invalid matching pattern: #{str}. Use: Module or Module.function"
    end
  end

  defp format_matching({:_, :_, :_}), do: "all functions"
  defp format_matching({mod, :_, :_}), do: "#{inspect(mod)}.*"
  defp format_matching({mod, func, :_}), do: "#{inspect(mod)}.#{func}/*"
  defp format_matching({mod, func, arity}), do: "#{inspect(mod)}.#{func}/#{arity}"

  defp collect_files(opts) do
    projects =
      case File.ls(@projects_dir) do
        {:ok, dirs} ->
          dirs
          |> Enum.filter(&File.dir?(Path.join(@projects_dir, &1)))
          |> Enum.map(&Path.join(@projects_dir, &1))

        {:error, _} ->
          IO.puts("Error: projects directory '#{@projects_dir}' not found")
          System.halt(1)
      end

    projects =
      if opts.project do
        Enum.filter(projects, &(Path.basename(&1) == opts.project))
      else
        projects
      end

    IO.puts("Projects: #{Enum.map(projects, &Path.basename/1) |> Enum.join(", ")}")

    files =
      projects
      |> Enum.flat_map(&collect_elixir_files/1)

    files =
      if opts.limit do
        Enum.take(files, opts.limit)
      else
        files
      end

    files
  end

  defp collect_elixir_files(root_path) do
    Path.wildcard(Path.join(root_path, "**/*.{ex,exs}"))
    |> Enum.reject(&should_ignore_file?/1)
  end

  defp should_ignore_file?(file_path) do
    path_parts = Path.split(file_path)
    filename = Path.basename(file_path)

    # Skip Phoenix installer templates
    phoenix_installer_templates =
      String.contains?(file_path, "projects/phoenix/installer/templates")

    phoenix_installer_templates or
      Enum.any?(@ignored_dirs, &(&1 in path_parts)) or
      filename in @ignored_files
  end

  def tokenize_file(file_path, backend \\ :charlist) do
    content = File.read!(file_path)
    byte_size = byte_size(content)
    stream = Toxic.new(content, 1, 1, lexer_backend: backend)
    {token_count, _stream} = count_tokens(stream, 0)
    {token_count, byte_size}
  end

  defp count_tokens(stream, count) do
    case Toxic.next(stream) do
      {:ok, _token, new_stream} ->
        count_tokens(new_stream, count + 1)

      {:eof, final_stream} ->
        {count, final_stream}

      {:error, _reason, new_stream} ->
        # Continue on errors in tolerant mode
        count_tokens(new_stream, count + 1)
    end
  end

  defp run_profile(files, opts) do
    # Prepare the workload function
    backend = opts.backend
    workload = fn ->
      Enum.reduce(files, {0, 0}, fn file, {total_tokens, total_bytes} ->
        {tokens, bytes} = tokenize_file(file, backend)
        {total_tokens + tokens, total_bytes + bytes}
      end)
    end

    # First, run without profiling to get baseline timing and stats
    IO.puts("Running baseline measurement...")
    {baseline_time, {total_tokens, total_bytes}} = :timer.tc(workload)
    baseline_ms = baseline_time / 1000

    IO.puts("")
    IO.puts("Baseline Results:")
    IO.puts("-----------------")
    IO.puts("Files processed: #{length(files)}")
    IO.puts("Total tokens: #{total_tokens}")
    IO.puts("Total bytes: #{total_bytes}")
    IO.puts("Baseline time: #{Float.round(baseline_ms, 2)} ms")
    IO.puts("Throughput: #{Float.round(total_tokens / (baseline_ms / 1000), 0)} tokens/sec")
    IO.puts("Throughput: #{Float.round(total_bytes / (baseline_ms / 1000) / 1024, 2)} KB/sec")
    IO.puts("")

    # Now run with profiling
    IO.puts("Running profiler (#{opts.profiler}, #{opts.type})...")
    IO.puts("")

    run_selected_profiler(workload, opts)
  end

  defp run_selected_profiler(workload, %{profiler: :fprof} = opts) do
    IO.puts("Using fprof")
    run_fprof(workload, opts)
  end

  defp run_selected_profiler(workload, %{profiler: :eprof} = opts) do
    IO.puts("Using eprof")
    profile_opts = build_eprof_opts(opts)
    run_eprof(workload, profile_opts)
  end

  defp run_selected_profiler(workload, %{profiler: :cprof} = opts) do
    IO.puts("Using cprof")
    profile_opts = [matching: opts.matching, warmup: opts.warmup]
    run_cprof(workload, profile_opts)
  end

  defp run_selected_profiler(workload, %{profiler: :tprof} = opts) do
    if Code.ensure_loaded?(:tprof) do
      IO.puts("Using tprof (OTP 27+)")
      profile_opts = build_tprof_opts(opts)
      run_tprof(workload, profile_opts)
    else
      IO.puts("tprof not available (requires OTP 27+), falling back to eprof")
      profile_opts = build_eprof_opts(opts)
      run_eprof(workload, profile_opts)
    end
  end

  defp run_selected_profiler(workload, %{profiler: :auto} = opts) do
    # Auto-select based on type and availability
    case opts.type do
      :time ->
        run_tprof_or_eprof(workload, opts)

      :memory ->
        if Code.ensure_loaded?(:tprof) do
          IO.puts("Using tprof for memory profiling (OTP 27+)")
          profile_opts = build_tprof_opts(opts)
          run_tprof(workload, profile_opts)
        else
          IO.puts("Memory profiling requires tprof (OTP 27+)")
          System.halt(1)
        end

      :calls ->
        run_cprof_or_tprof(workload, opts)
    end
  end

  defp build_tprof_opts(opts) do
    [type: opts.type, matching: opts.matching, warmup: opts.warmup]
    |> maybe_add_sort(opts)
  end

  defp build_eprof_opts(opts) do
    [matching: opts.matching, warmup: opts.warmup]
    |> maybe_add_sort(opts)
  end

  defp maybe_add_sort(opts_list, %{sort: nil}), do: opts_list
  defp maybe_add_sort(opts_list, %{sort: sort}), do: [{:sort, sort} | opts_list]

  defp run_tprof_or_eprof(workload, opts) do
    if Code.ensure_loaded?(:tprof) do
      IO.puts("Using tprof (OTP 27+)")
      profile_opts = build_tprof_opts(opts)
      run_tprof(workload, profile_opts)
    else
      IO.puts("Using eprof (tprof not available)")
      profile_opts = build_eprof_opts(opts)
      run_eprof(workload, profile_opts)
    end
  end

  defp run_cprof_or_tprof(workload, opts) do
    if Code.ensure_loaded?(:tprof) do
      IO.puts("Using tprof for call counting (OTP 27+)")
      profile_opts = build_tprof_opts(%{opts | type: :calls})
      run_tprof(workload, profile_opts)
    else
      IO.puts("Using cprof for call counting")
      run_cprof(workload, [matching: opts.matching, warmup: opts.warmup])
    end
  end

  defp run_tprof(workload, opts) do
    Mix.ensure_application!(:tools)
    Mix.Tasks.Profile.Tprof.profile(workload, opts)
  end

  defp run_eprof(workload, opts) do
    Mix.ensure_application!(:tools)
    Mix.Tasks.Profile.Eprof.profile(workload, opts)
  end

  defp run_cprof(workload, opts) do
    Mix.ensure_application!(:tools)
    Mix.Tasks.Profile.Cprof.profile(workload, opts)
  end

  defp run_fprof(workload, opts) do
    Mix.ensure_application!(:tools)
    Mix.ensure_application!(:runtime_tools)

    fprof_opts =
      [warmup: opts.warmup]
      |> maybe_add_fprof_callers(opts)
      |> maybe_add_fprof_details(opts)
      |> maybe_add_fprof_sort(opts)
      |> maybe_add_fprof_trace_to_file(opts)

    Mix.Tasks.Profile.Fprof.profile(workload, fprof_opts)
  end

  defp maybe_add_fprof_callers(opts_list, %{callers: true}), do: [{:callers, true} | opts_list]
  defp maybe_add_fprof_callers(opts_list, _), do: opts_list

  defp maybe_add_fprof_details(opts_list, %{details: true}), do: [{:details, true} | opts_list]
  defp maybe_add_fprof_details(opts_list, _), do: opts_list

  defp maybe_add_fprof_sort(opts_list, %{sort: sort}) when sort in [:acc, :own],
    do: [{:sort, sort} | opts_list]
  defp maybe_add_fprof_sort(opts_list, _), do: opts_list

  defp maybe_add_fprof_trace_to_file(opts_list, %{trace_to_file: true}),
    do: [{:trace_to_file, true} | opts_list]
  defp maybe_add_fprof_trace_to_file(opts_list, _), do: opts_list
end

# Run the profiler
ToxicProfiler.run(System.argv())
