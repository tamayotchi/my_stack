defmodule TamayotchiStack.Prompt do
  @moduledoc false

  @spec confirm(String.t(), boolean(), Keyword.t()) :: boolean()
  def confirm(message, default, options \\ []) do
    case Keyword.fetch(options, :value) do
      {:ok, value} when is_boolean(value) ->
        value

      _ ->
        if Keyword.get(options, :yes, false) do
          default
        else
          suffix = if default, do: "[Y/n]", else: "[y/N]"

          case Mix.shell().prompt("#{message} #{suffix}") |> String.trim() |> String.downcase() do
            "" ->
              default

            answer when answer in ["y", "yes"] ->
              true

            answer when answer in ["n", "no"] ->
              false

            _ ->
              Mix.shell().error("Please answer yes or no.")
              confirm(message, default, options)
          end
        end
    end
  end
end
