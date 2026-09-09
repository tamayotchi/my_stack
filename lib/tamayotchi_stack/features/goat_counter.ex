defmodule TamayotchiStack.Features.GoatCounter do
  @moduledoc false

  alias TamayotchiStack.Project

  @managed_marker "// Managed by tamayotchi_stack."
  @app_js "assets/js/app.js"
  @wrapper_path "assets/js/goatcounter.js"
  @vendor_path "assets/vendor/goatcounter.js"

  @spec endpoint_for_app(atom() | String.t()) :: String.t()
  def endpoint_for_app(app_name) do
    code =
      app_name
      |> to_string()
      |> String.downcase()
      |> String.replace("_", "-")

    "https://#{code}.goatcounter.com/count"
  end

  @spec configure(Igniter.t(), atom() | String.t()) :: Igniter.t()
  def configure(igniter, app_name) do
    if Project.phoenix?(igniter) do
      endpoint = endpoint_for_app(app_name)

      igniter
      |> put_managed_file(@wrapper_path, wrapper(endpoint))
      |> put_managed_file(@vendor_path, vendor_script())
      |> import_from_app_js()
      |> Igniter.add_notice("GoatCounter will send pageviews to #{endpoint}.")
    else
      Igniter.add_issue(
        igniter,
        "GoatCounter requires a Phoenix project with assets/js/app.js"
      )
    end
  end

  defp put_managed_file(igniter, path, desired) do
    Igniter.create_or_update_file(igniter, path, desired, fn source ->
      current = Rewrite.Source.get(source, :content)

      cond do
        current == desired ->
          source

        String.starts_with?(current, @managed_marker) ->
          Rewrite.Source.update(source, :content, desired)

        true ->
          {:error,
           "Refusing to overwrite unmanaged #{path}; adopt it manually or add #{@managed_marker}"}
      end
    end)
  end

  defp import_from_app_js(igniter) do
    Igniter.update_file(igniter, @app_js, fn source ->
      contents = Rewrite.Source.get(source, :content)

      if imports_goatcounter?(contents) do
        source
      else
        updated = insert_import(contents)
        Rewrite.Source.update(source, :content, updated)
      end
    end)
  end

  defp insert_import(contents) do
    phoenix_html_import = ~r/^import\s+["']phoenix_html["'];?[ \t]*$/m

    case Regex.run(phoenix_html_import, contents) do
      [existing] ->
        String.replace(
          contents,
          existing,
          existing <> "\nimport \"./goatcounter\";",
          global: false
        )

      nil ->
        "import \"./goatcounter\";\n" <> contents
    end
  end

  defp imports_goatcounter?(contents) do
    Regex.match?(~r/^import\s+["']\.\/goatcounter["'];?[ \t]*$/m, contents)
  end

  defp wrapper(endpoint) do
    """
    #{@managed_marker}
    window.goatcounter = window.goatcounter || {};
    window.goatcounter.endpoint = #{inspect(endpoint)};

    // Optional path normalization for pages with dynamic IDs. Uncomment and
    // adapt this when many URLs represent the same logical page. For example,
    // /products/123/history and /products/456/history become
    // /products/:id/history in GoatCounter.
    // window.goatcounter.path = (path) =>
    //   path.replace(
    //     /^\\/products\\/\\d+\\/(history|edit)(?:\\?.*)?$/,
    //     "/products/:id/$1",
    //   );

    let lastTrackedLocation = `${window.location.pathname}${window.location.search}`;

    window.addEventListener("phx:page-loading-stop", () => {
      if (typeof window.goatcounter.bind_events === "function") {
        window.goatcounter.bind_events();
      }

      const currentLocation = `${window.location.pathname}${window.location.search}`;

      if (
        currentLocation === lastTrackedLocation ||
        typeof window.goatcounter.count !== "function"
      ) {
        return;
      }

      lastTrackedLocation = currentLocation;
      window.goatcounter.count();
    });

    // Load the self-hosted GoatCounter client after configuring its endpoint.
    void import("../vendor/goatcounter");
    """
  end

  defp vendor_script do
    :tamayotchi_stack
    |> :code.priv_dir()
    |> Path.join("templates/goatcounter/count.js")
    |> File.read!()
  end
end
