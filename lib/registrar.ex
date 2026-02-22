defmodule DDTrace.Registrar do
  @moduledoc """
  A registrar that manages the reigstration of processes for deadlock monitoring.
  Spawns and monitors the underlying ddtrace monitors, and cleans up when they die.
  """
  require Logger
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Registers the calling process for deadlock monitoring.
  Returns the PID of the new ddtrace monitor (M) on success.
  """
  def register_me do
    try do
      GenServer.call(__MODULE__, {:register, self()})
    catch
      :exit, {reason, _} ->
        Logger.warning(
          "DDTrace.Registrar: Failed to register process #{inspect(self())} for monitoring. Reason: #{inspect(reason)}"
        )
        nil
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    # We trap exits so links don't kill us, but we rely on Monitors for logic
    Process.flag(:trap_exit, true)

    :mon_reg.ensure_started()

    Logger.info("DDTrace.Registrar: Started. Ready to register processes.")
    {:ok, %{monitors: %{}, refs: %{}}}
  end

  @impl true
  def terminate(reason, %{monitors: monitors} = _state) do
    Logger.info(
      "DDTrace.Registrar: Terminating with reason: #{inspect(reason)}. Terminating monitors: #{inspect(Map.keys(monitors))}"
    )

    # Stop all ddtrace monitors
    Enum.each(monitors, fn {_pid, monitor} ->
      :ddtrace.stop_tracer(monitor)
    end)

    :ok
  end

  @impl true
  def handle_call({:register, p_pid}, _from, %{monitors: monitors, refs: refs} = state) do
    if Map.has_key?(monitors, p_pid) do
      {:reply, {:ok, monitors[p_pid]}, state}
    else
      case :ddtrace.start_link(p_pid) do
        {:ok, m_pid} ->
          Logger.info(
            "DDTrace.Registrar: Started ddtrace monitor #{inspect(m_pid)} for process #{inspect(p_pid)}."
          )
          # Monitor only the m_pid (the tracer). If the p_pid dies, the
          # tracer will die too, and we'll get a :DOWN message to clean up.
          ref = Process.monitor(m_pid)

          # Store mapping so when Ref fires, we know which WorkerPID to clean up
          new_refs = Map.put(refs, ref, p_pid)
          new_monitors = Map.put(monitors, p_pid, m_pid)

          {:reply, {:ok, m_pid}, %{state | monitors: new_monitors, refs: new_refs}}

        error ->
          Logger.warning(
            "DDTrace.Registrar: Failed to start ddtrace monitor for process #{inspect(p_pid)}. Error: #{inspect(error)}"
          )

          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, m_pid, reason}, %{monitors: monitors, refs: refs} = state) do
    {p_pid, new_refs} = Map.pop(refs, ref)

    new_monitors = Map.delete(monitors, p_pid)

    case reason do
      :normal -> Logger.info("DDTrace.Registrar: Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} stopped normally.")
      _ -> Logger.warning("DDTrace.Registrar: Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} crashed: #{inspect(reason)}")
    end

    {:noreply, %{state | monitors: new_monitors, refs: new_refs}}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}
end
