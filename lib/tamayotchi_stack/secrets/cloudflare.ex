defmodule TamayotchiStack.Secrets.Cloudflare do
  @moduledoc false

  alias TamayotchiStack.Secrets.CloudflareHttp

  @derive {Inspect, only: [:bucket, :name, :private?, :exists?]}
  defstruct [:account, :token, :bucket, :name, :private?, :exists?, :permission, :client]

  @id ~r/\A[a-f0-9]{32}\z/
  @permission "Workers R2 Storage Bucket Item Write"
  @scope "com.cloudflare.edge.r2.bucket"
  @conflict "Cloudflare already has a token with this provisioning name. Its secret cannot be recovered. Reconcile it and the deployment item manually; automatic rotation/retries are refused."

  def prepare(account, token, bucket, name, private?, client \\ &CloudflareHttp.request/4) do
    job = %__MODULE__{
      account: account,
      token: token,
      bucket: bucket,
      name: name,
      private?: private?,
      client: client
    }

    with true <- is_binary(account) and Regex.match?(@id, account),
         true <- valid_bucket?(bucket),
         true <- is_binary(token) and String.trim(token) != "",
         :ok <- no_existing_token(job),
         {:ok, %{"result" => groups}} when is_list(groups) <-
           request(
             job,
             :get,
             "/tokens/permission_groups?" <>
               URI.encode_query(%{"name" => @permission, "scope" => @scope})
           ),
         [group] <-
           Enum.filter(groups, &(&1["name"] == @permission and @scope in (&1["scopes"] || []))),
         true <- is_binary(group["id"]) and Regex.match?(@id, group["id"]),
         {:ok, exists?} <- bucket_exists(job),
         :ok <- if(exists?, do: check_privacy(job), else: :ok) do
      {:ok, %{job | exists?: exists?, permission: group["id"]}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error,
         "Cannot safely plan Cloudflare provisioning. Check the account, bucket name, and bucket-scoped object-write permission."}
    end
  rescue
    _ -> {:error, "Cannot safely plan Cloudflare provisioning; response details suppressed"}
  end

  # The caller must durably save its provisioning marker before calling this.
  # Recheck external state, but never claim a cross-provider atomic transaction.
  def provision(job) do
    with :ok <- no_existing_token(job),
         :ok <- ensure_bucket(job),
         :ok <- check_privacy(job),
         {:ok, %{"result" => token}} <- request(job, :post, "/tokens", token_body(job)),
         true <- valid_token?(job, token) do
      {:ok,
       %{
         access_key: token["id"],
         secret_key: :crypto.hash(:sha256, token["value"]) |> Base.encode16(case: :lower)
       }}
    else
      _ ->
        {:error,
         "Cloudflare provisioning was not confirmed. A bucket/token may have been created. Inspect Cloudflare and the 1Password provisioning marker before retrying; nothing was automatically revoked or rotated."}
    end
  rescue
    _ ->
      {:error,
       "Cloudflare provisioning failed; inspect Cloudflare and the 1Password provisioning marker before retrying"}
  end

  def valid_bucket?(bucket) when is_binary(bucket) do
    Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/, bucket)
  end

  def valid_bucket?(_), do: false

  defp token_body(job) do
    %{
      "name" => job.name,
      "policies" => [
        %{
          "effect" => "allow",
          "permission_groups" => [%{"id" => job.permission}],
          "resources" => %{"#{@scope}.#{job.account}_default_#{job.bucket}" => "*"}
        }
      ]
    }
  end

  defp valid_token?(job, token) do
    expected = hd(token_body(job)["policies"])

    is_binary(token["id"]) and Regex.match?(@id, token["id"]) and
      is_binary(token["value"]) and byte_size(token["value"]) in 40..80 and
      token["status"] == "active" and token["name"] == job.name and
      case token["policies"] do
        [policy] ->
          policy["effect"] == "allow" and policy["resources"] == expected["resources"] and
            Enum.map(policy["permission_groups"] || [], & &1["id"]) == [job.permission]

        _ ->
          false
      end
  end

  defp no_existing_token(job) do
    with {:ok, tokens} <- list(job, "/tokens") do
      if Enum.any?(tokens, &(&1["name"] == job.name)), do: {:error, @conflict}, else: :ok
    end
  end

  # Cloudflare list endpoints may paginate. Never inspect only the first page
  # when deciding that a token is absent or a permission is unambiguous.
  defp list(job, path, page \\ 1, acc \\ [])

  defp list(_job, _path, page, _acc) when page > 100,
    do: {:error, "Cloudflare pagination limit reached; refusing to assume resources are absent"}

  defp list(job, path, page, acc) do
    with {:ok, %{"result" => results} = response} when is_list(results) <-
           request(job, :get, "#{path}?page=#{page}&per_page=50&include_expired=true") do
      all = acc ++ results
      info = response["result_info"] || %{}

      bounded? = is_integer(info["total_pages"]) or is_integer(info["total_count"])

      more? =
        (info["total_pages"] || page) > page or (info["total_count"] || length(all)) > length(all) or
          (not bounded? and length(results) >= (info["per_page"] || 50))

      cond do
        info["page"] not in [nil, page] -> {:error, "Cloudflare returned an unexpected page"}
        more? and results == [] -> {:error, "Cloudflare returned inconsistent pagination"}
        more? -> list(job, path, page + 1, all)
        true -> {:ok, all}
      end
    else
      _ ->
        {:error,
         "Could not list Cloudflare tokens/permissions; verify the bootstrap account permissions"}
    end
  end

  defp bucket_exists(job) do
    case request(job, :get, "/r2/buckets/#{job.bucket}") do
      {:ok, %{"result" => %{"name" => name} = bucket}} when name == job.bucket ->
        if bucket["jurisdiction"] in [nil, "default"],
          do: {:ok, true},
          else: {:error, "Automatic provisioning supports only default-jurisdiction R2 buckets"}

      {:error, :not_found} ->
        {:ok, false}

      _ ->
        {:error, "Cannot verify the configured Cloudflare bucket"}
    end
  end

  defp ensure_bucket(job) do
    case bucket_exists(job) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        case request(job, :post, "/r2/buckets", %{"name" => job.bucket}) do
          {:ok, %{"result" => %{"name" => name}}} when name == job.bucket -> :ok
          _ -> {:error, :bucket_creation_failed}
        end

      error ->
        error
    end
  end

  defp check_privacy(%{private?: false}), do: :ok

  defp check_privacy(job) do
    with {:ok, %{"result" => %{"enabled" => false}}} <-
           request(job, :get, "/r2/buckets/#{job.bucket}/domains/managed"),
         {:ok, %{"result" => %{"domains" => domains}}} when is_list(domains) <-
           request(job, :get, "/r2/buckets/#{job.bucket}/domains/custom"),
         true <- Enum.all?(domains, &(&1["enabled"] == false)) do
      :ok
    else
      _ ->
        {:error,
         "Backup bucket privacy could not be verified: disable r2.dev and public custom domains, or select a different private bucket"}
    end
  end

  defp request(job, method, path, body \\ nil),
    do: job.client.(method, "/accounts/#{job.account}" <> path, job.token, body)
end
