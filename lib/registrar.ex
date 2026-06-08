defmodule DDTrace.Registrar do
  @moduledoc """
  A registrar that manages the registration of processes for deadlock monitoring.
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
  Asynchronously registers the calling process for deadlock monitoring.
  """
  def register_me_async do
    register_async(self())
  end

  @doc """
  Asynchronously registers the process for deadlock monitoring.
  """
  def register_async(pid) do
    GenServer.cast(__MODULE__, {:register, pid})
  end

  @doc """
  Registers the calling process for deadlock monitoring.
  Returns the PID of the new ddtrace monitor (M) on success.
  """
  def register_me do
    register(self())
  end

  @doc """
  Registers the process for deadlock monitoring.
  Returns the PID of the new ddtrace monitor (M) on success.
  """
  def register(pid) do
    try do
      GenServer.call(__MODULE__, {:register, pid}, 5000)
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
  def init(init_args) do
    Process.flag(:trap_exit, true)

    :mon_reg.ensure_started()

    restart_policy = Keyword.get(init_args, :restart_policy, :only_panic)

    Logger.info("[REGISTRY] Started. Ready to register processes.")
    {:ok, %{monitors: %{}, refs: %{}, restart: restart_policy}}
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
  def handle_cast(:collect_garbage, state) do
    state.monitors
    |> Enum.each(fn {_p_pid, m_pid} ->
      :erlang.garbage_collect(m_pid)
      {_, m_procs} = Process.info(m_pid, :links)

      m_procs |> Enum.each(fn proc ->
        :erlang.garbage_collect(proc)
      end)
    end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:register, p_pid}, state) do
    case Map.fetch(state.monitors, p_pid) do
      {:ok, _} ->
        {:noreply, state}
      :error ->
        case register_worker(p_pid, state) do
          {:ok, _, new_state} ->
            {:noreply, new_state}
          _ ->
            {:noreply, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:register, p_pid}, _from, state) do
    case Map.fetch(state.monitors, p_pid) do
      {:ok, m_pid} ->
        {:reply, {:ok, m_pid}, state}
      :error ->
        case register_worker(p_pid, state) do
          {:ok, m_pid, new_state} ->
            {:reply, {:ok, m_pid}, new_state}
          error ->
            {:reply, error, state}
        end
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, m_pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        # We don't know about this monitor. Ignore it.
        {:noreply, state}
      {p_pid, refs_without_old} ->
        monitors_without_old = Map.delete(state.monitors, p_pid)
        log_down_reason(m_pid, p_pid, reason)

        if should_restart?(state.restart, reason) and Process.alive?(p_pid) do
          Logger.info("[REGISTRY] Restarting monitor for process #{inspect(p_pid)} due to policy: #{state.restart}.")

          case register_worker(p_pid, %{state | monitors: monitors_without_old, refs: refs_without_old}) do
            {:ok, _, new_state} ->
              {:noreply, new_state}
            _ ->
              {:noreply, %{state | monitors: monitors_without_old, refs: refs_without_old}}
          end
        else
          {:noreply, %{state | monitors: monitors_without_old, refs: refs_without_old}}
        end
    end
  end

  @impl GenServer
  def handle_info(_, state), do: {:noreply, state}

  # --- Private Helpers ---
  defp register_worker(p_pid, state) do
      case :ddtrace.start_link(p_pid) do
        {:ok, m_pid} ->
          Logger.info("[REGISTRY] Started deadlock monitor #{inspect(m_pid)} for #{inspect(p_pid)}.")

          ref = Process.monitor(m_pid)
          new_refs = Map.put(state.refs, ref, p_pid)
          new_monitors = Map.put(state.monitors, p_pid, m_pid)

          {:ok, m_pid, %{state | monitors: new_monitors, refs: new_refs}}
        error ->
          Logger.warning("[REGISTRY] Failed to start tracer for #{inspect(p_pid)}. Error: #{inspect(error)}")
          error
      end
  end

  # Never restart if the target process simply does not exist.
  # Prevents infinite crash loops from ddtrace's resolve_to_pid/1.
  defp should_restart?(_policy, :noproc), do: false
  defp should_restart?(_policy, {:noproc, _details}), do: false

  # :permanent always restarts
  defp should_restart?(:permanent, _reason), do: true

  # :temporary never restarts
  defp should_restart?(:temporary, _reason), do: false

  # :transient does NOT restart on a normal, clean shutdown
  defp should_restart?(:transient, :normal), do: false
  defp should_restart?(:transient, :shutdown), do: false
  defp should_restart?(:transient, {:shutdown, _}), do: false

  # :transient DOES restart on any other reason (crashes, panics, errors)
  defp should_restart?(:transient, _abnormal_reason), do: true

  # :only_panic only restarts on timeout panics
  defp should_restart?(:only_panic, :timeout_panic), do: true
  defp should_restart?(:only_panic, _reason), do: false

  defp log_down_reason(m_pid, p_pid, reason) when reason in [:normal, :shutdown] do
    Logger.info("[REGISTRY] Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} stopped cleanly (#{reason}).")
  end

  # Handle the tuple version of shutdown
  defp log_down_reason(m_pid, p_pid, {:shutdown, _details} = reason) do
    Logger.info("[REGISTRY] Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} stopped cleanly (#{inspect(reason)}).")
  end

  defp log_down_reason(m_pid, p_pid, :timeout_panic) do
    Logger.warning("[REGISTRY] Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} stopped due to timeout panic!")
  end

  defp log_down_reason(m_pid, p_pid, reason) do
    Logger.warning("[REGISTRY] Monitor #{inspect(m_pid)} for process #{inspect(p_pid)} crashed: #{inspect(reason)}")
  end
end
