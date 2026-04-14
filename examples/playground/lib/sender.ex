defmodule Sender do

  require Logger

  use GenServer

  def start do
    GenServer.start(__MODULE__, :ok, name: __MODULE__)
  end

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def send_message(message) do
    GenServer.call(__MODULE__, {:message, message})
  end

  def send_ignored_message(message) do
    GenServer.call(__MODULE__, {:send_ignored_message, message})
  end

  def create_deadlock do
    GenServer.call(__MODULE__, :create_lock)
  end

  @impl GenServer
  def init(init_opts) do
    DDTrace.Registrar.register_me()
    {:ok, init_opts}
  end

  @impl GenServer
  def handle_call({:send_ignored_message, payload}, _from, state) do
    try do
      {:ok, reply} = GenServer.call(Receiver, {:message_noreply, payload}, 1000)
      {:reply, {:ok, reply}, state}
    catch
      :exit, {:timeout, _details} ->
        {:reply, {:error, :receiver_timeout}, state}
    end
  end

  @impl GenServer
  def handle_call({:message, payload}, _from, state) do
    {:ok, reply} = GenServer.call(Receiver, {:message, payload}, 1000)
    {:reply, {:ok, reply}, state}
  end

  @impl GenServer
  def handle_call(:create_lock, _from, state) do
    {:ok, _} = GenServer.call(Receiver, :create_lock)
    {:reply, :not_locked, state}
  end
end
