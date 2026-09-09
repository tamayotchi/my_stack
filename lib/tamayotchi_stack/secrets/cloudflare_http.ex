defmodule TamayotchiStack.Secrets.CloudflareHttp do
  @moduledoc false

  @origin "https://api.cloudflare.com/client/v4"
  @failure "Cloudflare request failed; response details were suppressed to protect credentials. Check the bootstrap token's account and permissions. After a write, inspect Cloudflare and 1Password before retrying."

  # Do not use :httpc here: it can retry POST on 503 + Retry-After even with
  # autoredirect disabled. A duplicate token write can lose a one-time secret.
  # Req/Finch let us explicitly disable retries and redirects. Bearer tokens and
  # JSON remain in memory, never shell arguments or temporary files.
  def request(method, path, token, body \\ nil, transport \\ &Req.request/1) do
    with true <- method in [:get, :post],
         true <- String.starts_with?(path, "/accounts/"),
         true <-
           is_binary(token) and byte_size(token) in 1..16_384 and
             not Regex.match?(~r/[\x00-\x20\x7f]/, token),
         {:ok, _} <- Application.ensure_all_started(:req) do
      options = [
        url: @origin <> path,
        method: method,
        headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
        body: if(method == :post, do: Jason.encode!(body), else: nil),
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
            {:ok, %{"success" => true, "result" => _} = response} -> {:ok, response}
            _ -> {:error, @failure}
          end

        {:ok, %{status: 404}} when method == :get ->
          {:error, :not_found}

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
end
