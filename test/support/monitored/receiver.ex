defmodule MonitoredReceiver do

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
    {:ok, init_opts}
  end

  @impl GenServer
  def handle_call({:message_noreply, _msg}, _from, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:message_reply_after, delay}, from, state) do
    Process.send_after(self(), {:send_delayed_reply, from}, delay)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:message, _msg}, _from, state) do
    {:reply, {:ok, "Hello, Sender!"}, state}
  end

  @impl GenServer
  def handle_call(:create_lock, _from, state) do
    GenServer.call(MonitoredSender, :create_lock)
    {:reply, :not_locked, state}
  end

  @impl GenServer
  def handle_info({:send_delayed_reply, from}, state) do
    GenServer.reply(from, {:ok, "Sorry Sender, I'm late!"})

    {:noreply, state}
  end
end
