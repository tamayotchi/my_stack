defmodule TamayotchiStack.PublicHost do
  @moduledoc false

  @hostname ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @conflict "Cannot safely update the public host. Use literal block-style YAML with one env.clear.PHX_HOST and, when proxied, proxy.host in config/deploy.yml. Reconcile overrides, duplicate keys, aliases, flow collections, escaped double-quoted strings, or multi-host configuration manually."
  @quoted_or_comment ~r/"(?:\\.|[^"\\\r\n])*"|'(?:''|[^'\r\n])*'|#[^\n]*/

  def valid?(host),
    do: is_binary(host) and byte_size(host) <= 253 and Regex.match?(@hostname, host)

  def validate(host) do
    if valid?(host),
      do: :ok,
      else:
        {:error,
         "--host must be a lowercase DNS hostname such as track.tamayotchi.com, without a scheme, path, port, or wildcard"}
  end

  def from_manifest(manifest), do: get_in(manifest, [:features, :phoenix, :host])

  # Patch only these two scalar values. Never re-render deployment identity,
  # servers, volumes, buckets, secrets, comments, or unrelated proxy settings.
  def patch(deployment, host) do
    with :ok <- validate(host),
         true <- not String.contains?(deployment, ["<%", "\t"]),
         true <- simple_document?(deployment),
         true <- simple_role_proxies?(deployment),
         false <- Regex.match?(~r/^(?:---|\.\.\.|%YAML|%TAG)(?:\s|$)/m, deployment),
         {:ok, env} <- block(deployment, "env", 0),
         {:ok, clear} <- block(env, "clear", 2),
         1 <- definitions(deployment, "PHX_HOST", nil),
         {:ok, updated_clear} <- scalar(clear, "PHX_HOST", 4, host),
         updated_env = replace_lines(env, clear, updated_clear),
         updated = replace_lines(deployment, env, updated_env) do
      case definitions(updated, "proxy", 0) do
        0 ->
          {:ok, updated}

        1 ->
          with {:ok, proxy} <- block(updated, "proxy", 0),
               0 <- definitions(proxy, "hosts", 2),
               {:ok, updated_proxy} <- scalar(proxy, "host", 2, host) do
            {:ok, replace_lines(updated, proxy, updated_proxy)}
          else
            _ -> {:error, @conflict}
          end

        _ ->
          {:error, @conflict}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, @conflict}
    end
  end

  # A conservative YAML subset, not a YAML evaluator. Hidden host overrides can
  # occur in any role or Docker options, so inspecting only env.clear is unsafe.
  # Ignore comments and opaque quoted values when checking YAML syntax, but count
  # PHX_HOST mentions in values too (e.g. Docker's --env or secret aliases).
  defp simple_document?(source) do
    code =
      Regex.replace(@quoted_or_comment, source, fn
        "#" <> _comment -> ""
        quoted -> quoted
      end)

    unquoted =
      Regex.replace(@quoted_or_comment, code, fn quoted ->
        cond do
          quoted in ["\"<<\"", "'<<'"] -> "<<"
          String.starts_with?(quoted, "\"") and String.contains?(quoted, "\\") -> "!unsupported"
          true -> "literal"
        end
      end)

    length(Regex.scan(~r/\bPHX_HOST\b/, code)) == 1 and
      not String.contains?(unquoted, ["{", "}", "[", "]", "\"", "'"]) and
      not Regex.match?(~r/(?:^|\s)[&*!]|^\s*(?:-\s+)?(?:<<\s*:|[?:](?:\s|$))/m, unquoted)
  end

  defp simple_role_proxies?(source) do
    declarations = Regex.scan(~r/^ +(?:proxy|"proxy"|'proxy') *:[^\n]*$/m, source)

    Enum.all?(declarations, fn [line] ->
      Regex.match?(~r/^ +(?:proxy|"proxy"|'proxy') *: *(?:true|false) *(?:#.*)?$/, line)
    end)
  end

  defp block(source, key, indent) do
    spaces = String.duplicate(" ", indent)

    pattern =
      Regex.compile!(
        "^" <>
          spaces <>
          key <> ":[ ]*(?:#[^\\n]*)?\\n(.*?)(?=^ {0," <> to_string(indent) <> "}\\S|\\z)",
        "ms"
      )

    with 1 <- definitions(source, key, indent),
         [block, _body] <- Regex.run(pattern, source) do
      {:ok, block}
    else
      _ -> {:error, @conflict}
    end
  end

  defp scalar(source, key, indent, host) do
    spaces = String.duplicate(" ", indent)
    key_pattern = "(?:" <> key <> "|\"" <> key <> "\"|'" <> key <> "')"

    pattern =
      Regex.compile!(
        "^(" <> spaces <> key_pattern <> ":[ ]+)([\"']?)([A-Za-z0-9_.:-]+)\\2([ ]*(?:#.*)?)$",
        "m"
      )

    with 1 <- definitions(source, key, indent),
         [line, prefix, quote, _previous, suffix] <- Regex.run(pattern, source) do
      {:ok, replace_lines(source, line, prefix <> quote <> host <> quote <> suffix)}
    else
      _ -> {:error, @conflict}
    end
  end

  # Anchor replacements too: a matched line/block must never replace a suffix
  # of a more deeply nested key or of a similarly named section first.
  defp replace_lines(source, before, replacement) do
    Regex.replace(
      Regex.compile!("^" <> Regex.escape(before), "m"),
      source,
      fn _ -> replacement end,
      global: false
    )
  end

  defp definitions(source, key, indent) do
    spaces = if is_nil(indent), do: " *", else: String.duplicate(" ", indent)

    pattern =
      Regex.compile!(
        "^" <> spaces <> "(?:" <> key <> "|\"" <> key <> "\"|'" <> key <> "')[ ]*:",
        "m"
      )

    length(Regex.scan(pattern, source))
  end
end
