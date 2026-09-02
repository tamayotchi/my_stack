defmodule TamayotchiStack.Doctor do
  @moduledoc false

  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project

  @spec report() :: map()
  def report do
    manifest = Manifest.read_file()
    app_name = Mix.Project.config()[:app]
    managed_phoenix? = phoenix_enabled?(manifest)
    {managed_kamal?, expected_kamal_proxy?} = kamal_configuration(manifest)

    %{
      app: app_name,
      manifest: manifest_status(manifest),
      managed_phoenix: managed_phoenix?,
      managed_kamal: managed_kamal?,
      phoenix: Project.phoenix_on_disk?(),
      kamal: Project.kamal_on_disk?(),
      kamal_proxy: Project.kamal_proxy_on_disk?(),
      expected_kamal_proxy: expected_kamal_proxy?,
      goatcounter: Project.goatcounter_on_disk?(),
      goatcounter_endpoint: Project.goatcounter_endpoint_on_disk(),
      expected_goatcounter_endpoint:
        if(managed_phoenix?, do: GoatCounter.endpoint_for_app(app_name))
    }
  end

  @spec healthy?(map()) :: boolean()
  def healthy?(report) do
    report.manifest == :ok and
      (not report.managed_phoenix or
         (report.phoenix and report.goatcounter and
            report.goatcounter_endpoint == report.expected_goatcounter_endpoint)) and
      (not Map.get(report, :managed_kamal, false) or
         (report.kamal and report.kamal_proxy == report.expected_kamal_proxy))
  end

  @spec format(map()) :: String.t()
  def format(report) do
    """
    Tamayotchi Stack doctor

      Application:  #{report.app}
      Manifest:     #{status(report.manifest)}
      Phoenix:      #{feature_status(report.phoenix, report.managed_phoenix)}
      GoatCounter:  #{goatcounter_status(report)}
      Endpoint:     #{report.goatcounter_endpoint || "not configured"}
      Expected:     #{report.expected_goatcounter_endpoint || "not applicable"}
      Kamal:        #{feature_status(report.kamal, report.managed_kamal)}
      Kamal proxy:  #{proxy_status(report)}
    """
  end

  defp manifest_status({:ok, _manifest}), do: :ok
  defp manifest_status({:error, _reason}), do: :missing_or_invalid

  defp phoenix_enabled?({:ok, manifest}) do
    manifest
    |> Keyword.get(:features, [])
    |> Keyword.has_key?(:phoenix)
  end

  defp phoenix_enabled?({:error, _reason}), do: false

  defp kamal_configuration({:ok, manifest}) do
    case Keyword.get(Keyword.get(manifest, :features, []), :kamal) do
      config when is_list(config) -> {true, Keyword.get(config, :proxy, true)}
      _other -> {false, nil}
    end
  end

  defp kamal_configuration({:error, _reason}), do: {false, nil}

  defp proxy_status(%{managed_kamal: true, kamal_proxy: proxy, expected_kamal_proxy: proxy}) do
    if proxy, do: "enabled", else: "disabled"
  end

  defp proxy_status(%{managed_kamal: true}), do: "does not match manifest"
  defp proxy_status(_report), do: "not managed"

  defp goatcounter_status(%{managed_phoenix: true, goatcounter: true}),
    do: "configured (included with Phoenix)"

  defp goatcounter_status(%{managed_phoenix: true, goatcounter: false}),
    do: "missing (required by Phoenix)"

  defp goatcounter_status(%{goatcounter: true}), do: "configured (unmanaged)"
  defp goatcounter_status(_report), do: "not configured"

  defp feature_status(true, true), do: "configured (managed)"
  defp feature_status(false, true), do: "missing (managed)"
  defp feature_status(true, false), do: "configured (unmanaged)"
  defp feature_status(false, false), do: "not configured"

  defp status(:ok), do: "valid"
  defp status(:missing_or_invalid), do: "missing or invalid"
end
