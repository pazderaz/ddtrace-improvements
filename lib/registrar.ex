defmodule DDTrace.Registrar do
  @moduledoc """
  A registrar that manages the reigstration of processes for deadlock monitoring.
  Spawns and monitors the underlying ddtrace monitors, and cleans up when they die.
  """
  require Logger
  use GenServer

  def start(init_args \\ []) do
    GenServer.start(__MODULE__, init_args, name: __MODULE__)
  end

  def start_link(init_args \\ []) do
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @doc """
  Registers the calling process for deadlock monitoring.
  Returns the PID of the new ddtrace monitor (M) on success.
  """
  def register_me do
    try do
      GenServer.call(__MODULE__, {:register, self()}, 5000)
    catch
      :exit, {reason, _} ->
        Logger.warning(
          "[REGISTRY] Failed to register process #{inspect(self())} for monitoring. Reason: #{inspect(reason)}"
        )
        nil
    end
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(_init_args) do
    # We trap exits so links don't kill us, but we rely on Monitors for logic
    Process.flag(:trap_exit, true)

    :mon_reg.ensure_started()

    Logger.info("[REGISTRY] Started. Ready to register processes.")
    {:ok, %{monitors: %{}, refs: %{}}}
  end

  @impl GenServer
  def terminate(reason, %{monitors: monitors} = _state) do
    Logger.info(
      "[REGISTRY] Terminating with reason: #{inspect(reason)}. Terminating monitors: #{inspect(Map.keys(monitors))}"
    )

    # Stop all ddtrace monitors
    Enum.each(monitors, fn {_pid, monitor} ->
      :ddtrace.stop_tracer(monitor)
    end)

    :ok
  end

  @impl GenServer
  def handle_call({:register, p_pid}, _from, %{monitors: monitors, refs: refs} = state) do
    case Map.fetch(monitors, p_pid) do
      {:ok, m_pid} ->
        {:reply, {:ok, m_pid}, state}
      :error ->
        case :ddtrace.start_link(p_pid) do
          {:ok, m_pid} ->
            Logger.info("[REGISTRY] Started deadlock monitor #{inspect(m_pid)} for #{inspect(p_pid)}.")

            ref = Process.monitor(m_pid)
            new_refs = Map.put(refs, ref, p_pid)
            new_monitors = Map.put(monitors, p_pid, m_pid)

            {:reply, {:ok, m_pid}, %{state | monitors: new_monitors, refs: new_refs}}
          error ->
            Logger.warning("[REGISTRY] Failed to start tracer for #{inspect(p_pid)}. Error: #{inspect(error)}")
            {:reply, error, state}
        end
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, m_pid, reason}, %{monitors: monitors, refs: refs} = state) do
    {p_pid, new_refs} = Map.pop(refs, ref)

    new_monitors = Map.delete(monitors, p_pid)

    case reason do
      :normal -> Logger.info("[REGISTRY] Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} stopped normally.")
      _ -> Logger.warning("[REGISTRY] Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} crashed: #{inspect(reason)}")
    end

    {:noreply, %{state | monitors: new_monitors, refs: new_refs}}
  end

  @impl GenServer
  def handle_info(_, state), do: {:noreply, state}
end
