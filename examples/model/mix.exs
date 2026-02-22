defmodule Model.MixProject do
  use Mix.Project

  def project do
    [
      app: :model,
      version: "0.1.0",
      compilers: [:erlang] ++ Mix.compilers(),
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      erlc_paths: ["src"],
      erlc_include_path: "include",
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ddtrace, path: "../../"}
    ]
  end

  defp escript do
    [
      name: "ddtrace",
      main_module: DDTrace.Main,
      emu_args: "-sname ddtrace +P 10485760"
    ]
  end
end
