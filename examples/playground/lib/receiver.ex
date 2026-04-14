defmodule Receiver do

  require Logger

  use GenServer

  def start do
    GenServer.start(__MODULE__, :ok, name: __MODULE__)
  end

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(init_opts) do
    DDTrace.Registrar.register_me()
    {:ok, init_opts}
  end

  @impl GenServer
  def handle_call({:message_noreply, msg}, _from, state) do
    Logger.info("Receiver got message: #{msg}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:message, msg}, _from, state) do
    Logger.info("Receiver got message: #{msg}")
    {:reply, {:ok, "Hello, Sender!"}, state}
  end

  @impl GenServer
  def handle_call(:create_lock, _from, state) do
    {:ok, _} = GenServer.call(Sender, :create_lock)
    {:reply, :not_locked, state}
  end
end
