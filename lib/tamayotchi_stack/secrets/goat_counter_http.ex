defmodule TamayotchiStack.Secrets.GoatCounterHttp do
  @moduledoc false

  @failure "GoatCounter request failed; check the main-site URL, token, and permissions. Provider output was suppressed. After a write, inspect GoatCounter before retrying."

  def origin(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and
         Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,48}[a-z0-9])?\.goatcounter\.com\z/, uri.host) and
         uri.port == 443 and uri.path in [nil, "", "/"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, "https://" <> uri.host}
    else
      {:error,
       "GOATCOUNTER_SITE_URL must be your main https://<site>.goatcounter.com URL, without a path or credentials"}
    end
  rescue
    _ -> {:error, "Invalid GOATCOUNTER_SITE_URL"}
  end

  def origin(_), do: {:error, "Set GOATCOUNTER_SITE_URL in the bootstrap item"}

  def valid_token?(token),
    do: is_binary(token) and Regex.match?(~r/\A[A-Za-z0-9_-]{32,256}\z/, token)

  def request(method, origin, path, token, body \\ nil, transport \\ &Req.request/1) do
    with {:ok, ^origin} <- origin(origin),
         true <- valid_token?(token),
         true <-
           {method, path} in [
             {:get, "/api/v0/me"},
             {:get, "/api/v0/sites"},
             {:put, "/api/v0/sites"}
           ],
         {:ok, _} <- Application.ensure_all_started(:req) do
      # Hosted GoatCounter permits four requests/second. Pace this synchronous
      # command instead of retrying rejected or ambiguous writes.
      pace(origin)

      options = [
        url: origin <> path,
        method: method,
        headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
        body: if(method == :put, do: Jason.encode!(body), else: nil),
        decode_body: false,
        cache: false,
        retry: false,
        redirect: false,
        receive_timeout: 30_000,
        connect_options: [
          timeout: 15_000,
          transport_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
        ]
      ]

      case transport.(options) do
        {:ok, %{status: status, body: response}}
        when status in 200..299 and is_binary(response) and byte_size(response) <= 2_000_000 ->
          case Jason.decode(response) do
            {:ok, value}
            when is_map(value) and not is_map_key(value, "error") and
                   not is_map_key(value, "errors") ->
              {:ok, value}

            _ ->
              {:error, @failure}
          end

        {:ok, %{status: status}} when is_integer(status) and status not in 200..299 ->
          {:error, http_failure(status)}

        _ ->
          {:error, @failure}
      end
    else
      _ -> {:error, @failure}
    end
  rescue
    _ -> {:error, @failure}
  catch
    _, _ -> {:error, @failure}
  end

  defp http_failure(401),
    do:
      "GoatCounter rejected authentication (HTTP 401); check that the API token belongs to the configured main site. Token values were not displayed."

  defp http_failure(403),
    do:
      "GoatCounter denied the request (HTTP 403); check the token's site access and permissions. Response details were suppressed."

  defp http_failure(429),
    do:
      "GoatCounter rate limit reached (HTTP 429); wait before running the command again. No automatic retry was attempted."

  defp http_failure(status),
    do:
      "GoatCounter request failed (HTTP #{status}); response details were suppressed. After a write, inspect the site before retrying."

  defp pace(origin) do
    key = {__MODULE__, :last_request, origin}
    now = System.monotonic_time(:millisecond)
    if previous = Process.get(key), do: Process.sleep(max(350 - (now - previous), 0))
    Process.put(key, System.monotonic_time(:millisecond))
  end
end
