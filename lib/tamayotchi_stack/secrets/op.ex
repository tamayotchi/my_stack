defmodule TamayotchiStack.Secrets.Op do
  @moduledoc false

  @max_output 2_000_000
  @session_key {__MODULE__, :session}
  @failure "1Password CLI failed; check sign-in, account, vault access, and permissions. Its output was suppressed to protect secrets. If a write was attempted, inspect the item before retrying."

  # Desktop authorization follows the parent process. Keep a single shell parent
  # for ALL reads/writes in a synchronous CLI operation, not one per request.
  # No session token is retained. The process-local port is always closed on exit.
  def with_session(fun, options \\ []) do
    case Process.get(@session_key) do
      nil ->
        # A port can fail with :epipe before emitting an exit_status (for
        # example, a CLI that stops reading its input). Handle that as a redacted
        # transport failure instead of letting the linked port kill the task.
        previous_trap = Process.flag(:trap_exit, true)

        try do
          case open_session(options) do
            {:ok, session} ->
              Process.put(@session_key, session)

              try do
                fun.()
              after
                Process.delete(@session_key)
                close_session(session)
              end

            error ->
              error
          end
        after
          Process.flag(:trap_exit, previous_trap)
          if not previous_trap, do: propagate_link_failure()
        end

      _session when options == [] ->
        fun.()

      _ ->
        {:error, @failure}
    end
  end

  def request(arguments, input \\ nil, options \\ []) do
    input = if is_nil(input), do: "", else: Jason.encode!(input)

    cond do
      byte_size(input) > @max_output ->
        {:error, "The 1Password item exceeds the supported payload size; no write was attempted"}

      not valid_arguments?(arguments) ->
        {:error, @failure}

      true ->
        case Process.get(@session_key) do
          nil -> with_session(fn -> send_request(arguments, input) end, options)
          _ when options == [] -> send_request(arguments, input)
          _ -> {:error, @failure}
        end
    end
  rescue
    _ -> {:error, @failure}
  catch
    _, _ -> {:error, @failure}
  end

  defp valid_arguments?(arguments) do
    is_list(arguments) and length(arguments) in 1..64 and
      Enum.all?(arguments, fn arg ->
        is_binary(arg) and byte_size(arg) <= 16_384 and
          not String.contains?(arg, ["\n", "\r", <<0>>])
      end)
  end

  defp open_session(options) do
    executable = Keyword.get(options, :executable) || System.find_executable("op")
    timeout = System.find_executable("timeout")
    shell = System.find_executable("bash")
    head = System.find_executable("head")
    kill = System.find_executable("kill")
    seconds = Keyword.get(options, :timeout_seconds, 120)

    if executable && timeout && shell && head && kill && is_integer(seconds) && seconds > 0 do
      # Frame non-secret argv as newline-separated strings, followed by exactly
      # N JSON bytes. No eval, shell interpolation, secret variables, or files.
      # head supplies EOF to op without closing the long-lived parent's stdin.
      # JSON cannot contain raw RS/US characters, so they delimit exit status.
      # Bash pipefail detects a failed feeder even if op exits successfully before
      # consuming its JSON. -p ignores startup files, exported functions, and shell
      # options from the environment; it does not grant OS privileges.
      script = ~S"""
      exec 2>/dev/null
      # Keep the group leader supervised until timeout's KILL grace elapses,
      # even when a descendant ignores TERM. Normal quit does not use this trap.
      trap 'while :; do sleep 1; done' TERM
      head=$1; op=$2
      while IFS=' ' read -r auth count size; do
        [ "$auth" = quit ] && exit 0
        set -- "$op"
        i=0
        while [ "$i" -lt "$count" ]; do
          IFS= read -r arg || exit 1
          set -- "$@" "$arg"
          i=$((i + 1))
        done
        if [ "$auth" = 1 ]; then
          shift 2
          "$op" signin --raw "$@" >/dev/null || exit 1
          set -- "$op" whoami "$@"
        fi
        "$head" -c "$size" | "$@"
        status=$?
        printf '\036%s\037' "$status"
        [ "$status" = 0 ] || exit "$status"
      done
      """

      port =
        Port.open({:spawn_executable, timeout}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [
            "--signal=TERM",
            "--kill-after=5s",
            "1h",
            shell,
            "--noprofile",
            "--norc",
            "-p",
            "-o",
            "pipefail",
            "-c",
            script,
            "tamayotchi-op",
            head,
            executable
          ],
          env: [{~c"OP_DEBUG", ~c"false"}, {~c"OP_INCLUDE_ARCHIVE", ~c"false"}]
        ])

      {:os_pid, pid} = Port.info(port, :os_pid)
      {:ok, %{port: port, pid: pid, kill: kill, seconds: seconds}}
    else
      {:error, "Install 1Password CLI (op), Bash, coreutils (head/timeout), and kill first"}
    end
  rescue
    _ -> {:error, @failure}
  end

  defp send_request(arguments, input) do
    session = Process.get(@session_key)
    if session == :failed, do: throw(:failed_session)
    service_account? = String.trim(System.get_env("OP_SERVICE_ACCOUNT_TOKEN") || "") != ""
    authenticate? = match?(["whoami" | _], arguments) and not service_account?
    arguments = arguments ++ ["--format=json", "--cache=false", "--no-color"]
    header = "#{if authenticate?, do: 1, else: 0} #{length(arguments)} #{byte_size(input)}\n"

    true =
      Port.command(session.port, [header, Enum.intersperse(arguments, "\n"), "\n", input], [
        :nosuspend
      ])

    case collect(session.port, "", System.monotonic_time(:millisecond) + session.seconds * 1000) do
      {:ok, _} = result ->
        result

      error ->
        # Never automatically reopen/retry a failed session: a write may have
        # succeeded even when its reply could not be decoded or received.
        Process.put(@session_key, :failed)
        error
    end
  rescue
    _ ->
      Process.put(@session_key, :failed)
      {:error, @failure}
  catch
    _, _ -> {:error, @failure}
  end

  defp collect(port, buffer, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(buffer) + byte_size(data) <= @max_output + 8 ->
        buffer = buffer <> data

        case :binary.split(buffer, <<30>>) do
          [json, "0" <> <<31>>] ->
            decode(json)

          [_, status] ->
            if :binary.match(status, <<31>>) == :nomatch,
              do: collect(port, buffer, deadline),
              else: {:error, @failure}

          [_] ->
            collect(port, buffer, deadline)
        end

      {^port, {:data, _}} ->
        {:error, @failure}

      {^port, {:exit_status, _}} ->
        {:error, @failure}

      {:EXIT, ^port, _} ->
        {:error, @failure}
    after
      remaining -> {:error, @failure}
    end
  end

  defp decode(json) when byte_size(json) <= @max_output do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) or is_list(data) -> {:ok, data}
      _ -> {:error, @failure}
    end
  end

  defp decode(_), do: {:error, @failure}

  defp close_session(session) do
    port = session.port

    if Port.info(port) do
      Port.command(port, "quit 0 0\n", [:nosuspend])

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        100 ->
          # GNU timeout owns the process group. Terminate a stuck CLI and its
          # helpers, with a bounded grace period, without logging their output.
          signal(session, "TERM")

          receive do
            {^port, {:exit_status, _}} -> :ok
          after
            5_000 -> signal(session, "KILL")
          end
      end

      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> :ok
  after
    flush(session.port)
  end

  defp signal(session, signal) do
    System.cmd(session.kill, ["-#{signal}", "--", "-#{session.pid}"], stderr_to_stdout: true)
    :ok
  end

  # Do not swallow unrelated linked-process failures when restoring a caller
  # which did not trap exits. Native credential tasks are synchronous.
  defp propagate_link_failure do
    receive do
      {:EXIT, _pid, :normal} -> propagate_link_failure()
      {:EXIT, _pid, reason} -> exit(reason)
    after
      0 -> :ok
    end
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
      {:EXIT, ^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
