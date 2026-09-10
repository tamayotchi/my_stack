defmodule TamayotchiStack.SecretsGoatCounterHttpTest do
  use ExUnit.Case, async: true
  alias TamayotchiStack.Secrets.GoatCounterHttp, as: Http

  @origin "https://parent.goatcounter.com"
  @token String.duplicate("synthetic-goat-token", 3)

  test "accepts only a hosted HTTPS main-site origin, without credentials or redirects" do
    assert {:ok, @origin} = Http.origin(@origin <> "/")

    for origin <- [
          nil,
          "REPLACE_ME",
          "http://parent.goatcounter.com",
          "https://evil.test",
          "https://goatcounter.com.evil.test",
          "https://user:password@parent.goatcounter.com",
          @origin <> "/api/v0",
          @origin <> "?token=secret",
          @origin <> "#secret",
          @origin <> ":444"
        ] do
      assert {:error, _} = Http.origin(origin)
    end

    for token <- [nil, "REPLACE_ME", @token <> "\r\nX-Header: bad"] do
      refute Http.valid_token?(token)
    end
  end

  test "validates boundaries before calling the transport" do
    transport = fn _ -> flunk("invalid input reached transport") end

    for {method, origin, path, token} <- [
          {:delete, @origin, "/api/v0/sites", @token},
          {:get, @origin, "/elsewhere", @token},
          {:get, "https://evil.test", "/api/v0/me", @token},
          {:put, @origin, "/api/v0/sites", "REPLACE_ME"}
        ] do
      assert {:error, _} = Http.request(method, origin, path, token, nil, transport)
    end
  end

  test "sends only the create payload and disables retries, redirects, and caching" do
    payload = %{code: "my-app", link_domain: "https://my-app.example.com"}

    transport = fn options ->
      assert options[:url] == @origin <> "/api/v0/sites"
      assert options[:method] == :put
      assert {"authorization", "Bearer " <> @token} in options[:headers]

      assert Jason.decode!(options[:body]) == %{
               "code" => "my-app",
               "link_domain" => "https://my-app.example.com"
             }

      assert options[:retry] == false
      assert options[:redirect] == false
      assert options[:cache] == false
      assert options[:connect_options][:transport_opts][:verify] == :verify_peer
      {:ok, %{status: 200, body: ~s({"id":2,"code":"my-app"})}}
    end

    assert {:ok, %{"id" => 2}} =
             Http.request(:put, @origin, "/api/v0/sites", @token, payload, transport)
  end

  test "existing GoatCounter sites cannot be updated or deleted by the transport" do
    for method <- [:patch, :post, :delete] do
      assert {:error, _} =
               Http.request(
                 method,
                 @origin,
                 "/api/v0/sites/2",
                 @token,
                 %{link_domain: "https://track.tamayotchi.com"},
                 fn _ ->
                   flunk("site modification reached transport")
                 end
               )
    end
  end

  test "rejects error envelopes and oversized responses without revealing provider output" do
    for response <- [
          {:ok, %{status: 401, body: @token}},
          {:ok, %{status: 200, body: Jason.encode!(%{error: @token})}},
          {:ok, %{status: 200, body: Jason.encode!(%{errors: %{token: @token}})}},
          {:ok, %{status: 200, body: String.duplicate("x", 2_000_001)}},
          {:error, @token}
        ] do
      assert {:error, error} =
               Http.request(:get, @origin, "/api/v0/me", @token, nil, fn _ -> response end)

      refute error =~ @token
    end
  end

  test "HTTP status errors stay actionable while response bodies remain hidden" do
    for {status, expected} <- [
          {401, "authentication"},
          {403, "denied"},
          {429, "rate limit"},
          {503, "HTTP 503"}
        ] do
      assert {:error, error} =
               Http.request(:get, @origin, "/api/v0/me", @token, nil, fn _ ->
                 {:ok, %{status: status, body: @token}}
               end)

      assert error =~ expected
      assert error =~ "HTTP #{status}"
      refute error =~ @token
    end
  end

  test "a real HTTP 503 with Retry-After results in one PUT, not an implicit retry" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = receive_headers(socket, "")
        assert request =~ "PUT /api/v0/sites HTTP/1.1"

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
        assert {:error, :timeout} = :gen_tcp.accept(listener, 700)
      end)

    transport = fn options ->
      options |> Keyword.put(:url, "http://127.0.0.1:#{port}/api/v0/sites") |> Req.request()
    end

    assert {:error, _} =
             Http.request(:put, @origin, "/api/v0/sites", @token, %{code: "test-app"}, transport)

    Task.await(server, 6_000)
  end

  defp receive_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      receive_headers(socket, buffer <> data)
    end
  end
end
