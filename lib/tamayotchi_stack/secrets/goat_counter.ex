defmodule TamayotchiStack.Secrets.GoatCounter do
  @moduledoc false
  import Bitwise

  alias TamayotchiStack.Features.GoatCounter, as: Feature
  alias TamayotchiStack.Secrets
  alias TamayotchiStack.Secrets.GoatCounterHttp

  @marker "TAMAYOTCHI_GOATCOUNTER_PROVISIONING"
  @conflict "GoatCounter provisioning is unresolved or targets a different account. Inspect the site and TAMAYOTCHI_GOATCOUNTER_PROVISIONING in 1Password; automatic recreation or retargeting is refused."
  @failure "Cannot safely configure GoatCounter. Check the main-site URL, token permissions, and site ownership; provider details suppressed."
  @reserved ~w(www mail smtp imap static admin ns1 ns2 m mobile api dev test beta new staging debug pprof chat example yoursite sql license stat stats)
  @derive {Inspect, only: [:code, :exists?]}
  defstruct [:origin, :token, :code, :parent, :link_domain, :exists?, :client]

  def prepare(base, app, url, token, link_domain, client \\ &GoatCounterHttp.request/5) do
    code =
      app
      |> Feature.endpoint_for_app()
      |> URI.parse()
      |> Map.fetch!(:host)
      |> String.replace_suffix(".goatcounter.com", "")

    with {:ok, origin} <- GoatCounterHttp.origin(url),
         true <- GoatCounterHttp.valid_token?(token),
         true <- valid_code?(code),
         true <- valid_link_domain?(link_domain),
         job = %__MODULE__{
           origin: origin,
           token: token,
           code: code,
           link_domain: link_domain,
           client: client
         },
         {:ok, permissions} <- permissions(job),
         {:ok, parent, site} <- lookup(job),
         job = %{job | parent: parent, exists?: not is_nil(site)},
         true <- job.exists? or band(permissions, 16) == 16,
         :ok <- checkpoint(base, job) do
      {:ok, job}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error,
         @failure <>
           " Use Read sites + Create sites permissions and an application code of 2–50 characters that is not reserved."}
    end
  rescue
    _ -> {:error, @failure}
  catch
    _, _ -> {:error, @failure}
  end

  def apply(base, nil), do: {:ok, base}
  def apply(base, %__MODULE__{exists?: true}), do: {:ok, base}

  def apply(base, job) do
    # Re-read before the checkpoint and PUT. Reuse a site created since the plan
    # instead of editing it. A pending checkpoint can only be resolved by finding
    # the owned site; it never authorizes another PUT after an ambiguous outcome.
    with {:ok, parent, site} <- lookup(job),
         true <- parent == job.parent do
      if site do
        {:ok, base}
      else
        with :ok <- checkpoint(base, job),
             {:ok, marked} <-
               Secrets.save_values(base, %{@marker => target(job)}, [{@marker, "CONCEALED"}]),
             {:ok, created} <-
               request(job, :put, "/api/v0/sites", %{code: job.code, link_domain: job.link_domain}),
             true <- compatible_site?(created, job.code, job.parent),
             true <- created["link_domain"] == job.link_domain,
             {:ok, ^parent, verified} <- lookup(job),
             true <- is_map(verified) and verified["id"] == created["id"] do
          {:ok, marked}
        else
          _ -> {:error, @failure}
        end
      end
    else
      _ -> {:error, @failure}
    end
  rescue
    _ -> {:error, @failure}
  catch
    _, _ -> {:error, @failure}
  end

  defp checkpoint(base, job) do
    case Secrets.field_value(base.current, @marker) do
      {:ok, value} when value in [nil, ""] -> :ok
      {:ok, value} -> if(job.exists? and value == target(job), do: :ok, else: {:error, @conflict})
      _ -> {:error, @conflict}
    end
  end

  defp target(job), do: job.origin <> "/" <> job.code

  defp permissions(job) do
    case request(job, :get, "/api/v0/me") do
      {:ok, %{"token" => %{"permissions" => permissions}}}
      when is_integer(permissions) and permissions >= 0 ->
        if band(permissions, 8) == 8,
          do: {:ok, permissions},
          else: {:error, "The GoatCounter API token is missing Read sites permission"}

      {:error, _} = error ->
        error

      _ ->
        {:error,
         "GoatCounter returned an unexpected permissions response; no write was attempted"}
    end
  end

  defp lookup(job) do
    origin_code =
      job.origin
      |> URI.parse()
      |> Map.fetch!(:host)
      |> String.replace_suffix(".goatcounter.com", "")

    with {:ok, %{"sites" => sites}} when is_list(sites) <- request(job, :get, "/api/v0/sites"),
         [parent] <- Enum.filter(sites, &(&1["code"] == origin_code)),
         true <- valid_site?(parent) and is_nil(parent["parent"]),
         matches = Enum.filter(sites, &(&1["code"] == job.code)) do
      case matches do
        [] ->
          {:ok, parent["id"], nil}

        [site] ->
          if compatible_site?(site, job.code, parent["id"]),
            do: {:ok, parent["id"], site},
            else: {:error, @failure}

        _ ->
          {:error, @failure}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, @failure}
    end
  end

  defp compatible_site?(site, code, parent) do
    valid_site?(site) and site["code"] == code and
      ((site["id"] != parent and site["parent"] == parent) or
         (site["id"] == parent and is_nil(site["parent"])))
  end

  # The hosted API uses the wire code "a", not the display label "active".
  defp valid_site?(site),
    do: is_map(site) and is_integer(site["id"]) and site["id"] > 0 and site["state"] == "a"

  defp valid_code?(code),
    do: code not in @reserved and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,48}[a-z0-9]\z/, code)

  defp valid_link_domain?(url) do
    uri = URI.parse(url)

    uri.scheme == "https" and is_binary(uri.host) and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, uri.host) and
      url == "https://" <> uri.host
  end

  defp request(job, method, path, body \\ nil),
    do: job.client.(method, job.origin, path, job.token, body)
end
