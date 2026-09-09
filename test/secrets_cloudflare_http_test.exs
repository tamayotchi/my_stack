defmodule TamayotchiStack.SecretsCloudflareHttpTest do
  use ExUnit.Case, async: true
  alias TamayotchiStack.Secrets.CloudflareHttp

  @token "test-only-sensitive-bearer"
  @path "/accounts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/tokens"

  test "uses a fixed HTTPS origin, verified TLS, timeouts, and no retries/redirects" do
    transport = fn options ->
      assert options[:url] == "https://api.cloudflare.com/client/v4" <> @path
      assert options[:method] == :post
      assert {"authorization", "Bearer " <> @token} in options[:headers]
      assert Jason.decode!(options[:body]) == %{"name" => "test-only"}
      assert options[:cache] == false
      assert options[:retry] == false
      assert options[:redirect] == false
      assert options[:receive_timeout] == 30_000
      assert options[:connect_options][:timeout] == 15_000
      assert options[:connect_options][:transport_opts][:verify] == :verify_peer
      assert [_ | _] = options[:connect_options][:transport_opts][:cacerts]
      {:ok, %{status: 200, body: ~s({"success":true,"result":{"id":"test"}})}}
    end

    assert {:ok, %{"result" => %{"id" => "test"}}} =
             CloudflareHttp.request(:post, @path, @token, %{"name" => "test-only"}, transport)
  end

  test "provider errors, redirects, invalid JSON, oversized responses, and exceptions stay redacted" do
    for response <- [
          {:ok, %{status: 403, body: @token}},
          {:ok,
           %{status: 302, headers: %{"location" => ["https://untrusted.invalid"]}, body: @token}},
          {:ok, %{status: 200, body: @token}},
          {:ok, %{status: 200, body: Jason.encode!(%{"success" => false, "result" => @token})}},
          {:ok, %{status: 200, body: String.duplicate("x", 2_000_001)}},
          {:error, @token}
        ] do
      ref = make_ref()

      transport = fn _ ->
        send(self(), ref)
        response
      end

      assert {:error, message} = CloudflareHttp.request(:post, @path, @token, %{}, transport)
      refute message =~ @token
      assert_receive ^ref
      refute_receive ^ref, 0
    end

    assert {:error, message} =
             CloudflareHttp.request(:get, @path, @token, nil, fn _ -> raise @token end)

    refute message =~ @token
  end

  test "only GET 404 is classified as absence; invalid methods never reach the transport" do
    transport = fn _ -> {:ok, %{status: 404, body: ""}} end
    assert {:error, :not_found} = CloudflareHttp.request(:get, @path, @token, nil, transport)
    assert {:error, message} = CloudflareHttp.request(:post, @path, @token, %{}, transport)
    assert is_binary(message)

    assert {:error, _} =
             CloudflareHttp.request(:delete, @path, @token, nil, fn _ ->
               flunk("must not send deletion requests")
             end)
  end

  test "control characters in authorization values are refused before transport" do
    assert {:error, _} =
             CloudflareHttp.request(:post, @path, "invalid\r\nheader", %{}, fn _ ->
               flunk("header injection")
             end)
  end

  test "the actual HTTP client sends POST only once on 503 with Retry-After" do
    # A loopback server catches implicit HTTP-library retries (OTP :httpc retries
    # this response). Only this injected test transport overrides the fixed URL.
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parent = self()
    worker = spawn_link(fn -> respond(listener, parent) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(worker, :kill)
    end)

    transport = fn options ->
      options
      |> Keyword.put(:url, "http://127.0.0.1:#{port}/tokens")
      |> Keyword.put(:connect_options, timeout: 15_000)
      |> Req.request()
    end

    assert {:error, message} = CloudflareHttp.request(:post, @path, @token, %{}, transport)
    refute message =~ @token
    assert_receive :post_received
    refute_receive :post_received, 100
  end

  defp respond(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        if String.starts_with?(request, "POST "), do: send(parent, :post_received)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
        respond(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end
end
