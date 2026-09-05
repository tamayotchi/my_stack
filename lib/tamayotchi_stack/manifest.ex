defmodule TamayotchiStack.Manifest do
  @moduledoc false

  @path ".tamayotchi.exs"
  @schema 1

  @spec path() :: String.t()
  def path, do: @path

  @spec set_feature(Igniter.t(), atom(), atom(), boolean(), keyword()) :: Igniter.t()
  def set_feature(igniter, app_name, feature, enabled?, config \\ [])
      when is_atom(app_name) and is_atom(feature) and is_boolean(enabled?) and is_list(config) do
    initial_features = if enabled?, do: [{feature, config}], else: []
    initial = manifest(app_name, initial_features)

    Igniter.create_or_update_file(igniter, @path, render(initial), fn source ->
      with {:ok, current} <- parse(Rewrite.Source.get(source, :content)),
           :ok <- validate_app(current, app_name) do
        current
        |> update_feature(feature, enabled?, config)
        |> remove_legacy_feature_state()
        |> render()
        |> then(&Rewrite.Source.update(source, :content, &1))
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec read(Igniter.t()) :: {:ok, keyword()} | {:error, String.t()}
  def read(igniter) do
    if Igniter.exists?(igniter, @path) do
      igniter = Igniter.include_existing_file(igniter, @path, required?: true)

      igniter.rewrite
      |> Rewrite.source!(@path)
      |> Rewrite.Source.get(:content)
      |> parse()
    else
      {:error, "#{@path} does not exist; run mix tamayotchi.setup first"}
    end
  end

  @spec read_file(Path.t()) :: {:ok, keyword()} | {:error, String.t()}
  def read_file(path \\ @path) do
    with {:ok, contents} <- File.read(path) do
      parse(contents)
    else
      {:error, :enoent} -> {:error, "#{path} does not exist"}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec parse(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def parse(contents) do
    with {:ok, quoted} <- Code.string_to_quoted(contents),
         true <- Macro.quoted_literal?(quoted),
         {manifest, []} <- Code.eval_quoted(quoted),
         true <- Keyword.keyword?(manifest),
         @schema <- Keyword.get(manifest, :schema),
         app when is_atom(app) <- Keyword.get(manifest, :app),
         features when is_list(features) <- Keyword.get(manifest, :features, []),
         true <- Keyword.keyword?(features),
         :ok <- validate_features(features) do
      {:ok, manifest}
    else
      {:error, {line, error, token}} ->
        {:error, "invalid #{@path} at line #{line}: #{error} #{inspect(token)}"}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error,
         "#{@path} must be a literal keyword list with schema: #{@schema}, app:, and features:"}
    end
  end

  @spec render(keyword()) :: String.t()
  def render(manifest) do
    inspect(manifest, pretty: true, width: 100, limit: :infinity) <> "\n"
  end

  defp manifest(app_name, features) do
    [schema: @schema, app: app_name, features: features]
  end

  defp update_feature(current, feature, true, config) do
    features = current |> Keyword.get(:features, []) |> Keyword.put(feature, config)
    Keyword.replace!(current, :features, features)
  end

  defp update_feature(current, feature, false, _config) do
    features = current |> Keyword.get(:features, []) |> Keyword.delete(feature)
    Keyword.replace!(current, :features, features)
  end

  # GoatCounter used to be represented as an independent feature. It is now an
  # invariant of Phoenix and therefore has no separate enabled/disabled state.
  defp remove_legacy_feature_state(current) do
    features = current |> Keyword.fetch!(:features) |> Keyword.delete(:goatcounter)
    Keyword.replace!(current, :features, features)
  end

  defp validate_features(features) do
    phoenix_config = Keyword.get(features, :phoenix, [])
    kamal_config = Keyword.get(features, :kamal, [])

    cond do
      Keyword.has_key?(features, :phoenix) and phoenix_config != [] ->
        {:error, "#{@path} Phoenix configuration must be []"}

      Keyword.has_key?(features, :backups) and Keyword.get(features, :backups) != [] ->
        {:error,
         "#{@path} backups configuration must be []; use app-owned config and runtime environment variables"}

      Keyword.has_key?(features, :r2) and Keyword.get(features, :r2) != [] ->
        {:error, "#{@path} R2 configuration must be []; use runtime environment variables"}

      Keyword.has_key?(features, :kamal) and not valid_kamal_config?(kamal_config) ->
        {:error, "#{@path} Kamal configuration must contain only proxy: true or proxy: false"}

      true ->
        :ok
    end
  end

  defp valid_kamal_config?(config) do
    is_list(config) and Keyword.keyword?(config) and
      Keyword.keys(config) in [[], [:proxy]] and
      is_boolean(Keyword.get(config, :proxy, true))
  end

  defp validate_app(current, app_name) do
    case Keyword.fetch(current, :app) do
      {:ok, ^app_name} -> :ok
      {:ok, other} -> {:error, "#{@path} belongs to #{inspect(other)}, not #{inspect(app_name)}"}
      :error -> {:error, "#{@path} is missing :app"}
    end
  end
end
