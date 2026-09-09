defmodule TamayotchiStack.New do
  @moduledoc false

  @app_name ~r/^[a-z][a-z0-9_]*$/
  @default_github "tamayotchi/my_stack"
  @dev_path_env "TAMAYOTCHI_STACK_DEV_PATH"

  @spec validate_app_name(String.t()) :: :ok | {:error, String.t()}
  def validate_app_name(app_name) do
    if Regex.match?(@app_name, app_name) do
      :ok
    else
      {:error,
       "application name must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"}
    end
  end

  @spec goatcounter_endpoint_for_app(String.t()) :: String.t()
  def goatcounter_endpoint_for_app(app_name) do
    code = String.replace(app_name, "_", "-")
    "https://#{code}.goatcounter.com/count"
  end

  @spec dependency() :: String.t()
  def dependency do
    case System.get_env(@dev_path_env) do
      path when path in [nil, ""] ->
        ~s({:tamayotchi_stack, github: "#{@default_github}", only: [:dev, :test], runtime: false})

      path ->
        expanded = Path.expand(path)
        ~s({:tamayotchi_stack, path: #{inspect(expanded)}, only: [:dev, :test], runtime: false})
    end
  end

  @spec inject_dependency(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def inject_dependency(contents, dependency) do
    cond do
      String.contains?(contents, "{:tamayotchi_stack,") ->
        {:ok, contents}

      Regex.match?(~r/defp deps do\s*\n\s*\[/, contents) ->
        updated =
          Regex.replace(
            ~r/(defp deps do\s*\n\s*\[)/,
            contents,
            "\\1\n      #{dependency},",
            global: false
          )

        {:ok, updated}

      true ->
        {:error, "could not find the dependency list in generated mix.exs"}
    end
  end

  @spec setup_arguments(boolean(), boolean(), boolean(), boolean()) :: [String.t()]
  def setup_arguments(phoenix?, r2?, proxy?, secrets? \\ true) do
    arguments = [
      "tamayotchi_stack.install",
      "--yes",
      if(phoenix?, do: "--phoenix", else: "--no-phoenix"),
      if(r2?, do: "--r2", else: "--no-r2")
    ]

    arguments = if secrets?, do: arguments, else: arguments ++ ["--no-secrets"]
    if phoenix?, do: arguments ++ [if(proxy?, do: "--proxy", else: "--no-proxy")], else: arguments
  end

  @spec run_command!(String.t(), [String.t()], keyword()) :: :ok
  def run_command!(command, arguments, options \\ []) do
    display = Enum.map_join([command | arguments], " ", &shell_escape/1)
    Mix.shell().info([:cyan, "$ #{display}", :reset])

    command_options =
      options
      |> Keyword.take([:cd])
      |> Keyword.merge(into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    case System.cmd(command, arguments, command_options) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("command failed with exit status #{status}: #{display}")
    end
  end

  defp shell_escape(value) do
    if String.match?(value, ~r/^[A-Za-z0-9_\.\/:,@=-]+$/) do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end
end
