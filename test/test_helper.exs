
Application.ensure_all_started(:logger)
Application.ensure_all_started(MicrochipFactory.Registry)

{:ok, _} = DDTrace.Registrar.start()

ExUnit.start()
