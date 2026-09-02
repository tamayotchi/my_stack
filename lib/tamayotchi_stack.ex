defmodule TamayotchiStack do
  @moduledoc """
  Development-time configuration and synchronization for Tamayotchi applications.

  Tamayotchi Stack writes app-owned implementation into a target repository. It
  does not provide a runtime proxy around Phoenix, GoatCounter, or future
  integrations.
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the installed Tamayotchi Stack version."
  def version, do: @version
end
