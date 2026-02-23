defmodule Ddtrace.MixProject do
  use Mix.Project

  @ddt_debug Application.compile_env(:ddtrace, :ddt_debug, "0")

  def project do
    [
      app: :ddtrace,
      version: "0.1.0",
      compilers: [:erlang] ++ Mix.compilers(),
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: ["lib"],
      erlc_paths: ["src"],
      erlc_include_path: "include",
      erlc_options: erlc_options(),
      deps: []
    ]
  end

  defp erlc_options do
    base_opts = [:debug_info]

    # Enable DDT_DEBUG only if DDT_DEBUG env var is set
    if @ddt_debug == "1" do
      [{:d, :DDT_DEBUG} | base_opts]
    else
      base_opts
    end
  end

  def application do
    [extra_applications: [:logger]]
  end
end
