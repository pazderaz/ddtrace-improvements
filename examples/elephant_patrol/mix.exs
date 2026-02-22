defmodule ElephantPatrol.MixProject do
  use Mix.Project

  def project do
    [
      app: :elephant_patrol,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ddtrace, path: "../../"}
    ]
  end
end
