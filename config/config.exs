import Config

config :logger,
  level: if(config_env() in [:test], do: :warning, else: :debug)
