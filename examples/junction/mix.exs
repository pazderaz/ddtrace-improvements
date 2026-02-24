defmodule Junction.MixProject do
  use Mix.Project

  def project do
    [
      app: :junction,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Junction.Application, []}
    ]
  end

  defp deps do
    [
      {:gen_state_machine, "~> 3.0"},
      {:ddtrace, path: "../../"}
    ]
  end
end
