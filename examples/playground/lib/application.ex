defmodule Playground.Application do
  use Application

  def start(_type, _args) do
    children = [
      DDTrace.Registrar
    ]

    opts = [strategy: :one_for_one, name: Playground.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
