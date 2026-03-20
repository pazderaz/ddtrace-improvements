defmodule Ddtrace.MixProject do
  use Mix.Project

  @ddt_debug Application.compile_env(:ddtrace, :ddt_debug, "0")
  @ddt_report Application.compile_env(:ddtrace, :ddt_report, false)

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
    [
      :debug_info,
      if(@ddt_debug == "1", do: {:d, :DDT_DEBUG}),
      if(@ddt_report == true, do: {:d, :DDT_REPORT})
    ] |> Enum.reject(&is_nil/1)
  end

  def application do
    [extra_applications: [:logger]]
  end
end
