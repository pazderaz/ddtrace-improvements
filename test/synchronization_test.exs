defmodule DDTrace.SynchronizationTest do
  use ExUnit.Case
  require Logger

  @moduletag timeout: 2000

  test "synchronization follows trace order in misordered sequence" do
    # 1. Start the monitor registry to avoid fake herald generation
    :mon_reg.ensure_started()

    # 2. Start a dummy worker
    {:ok, worker_pid} = Agent.start(fn -> :ok end)

    # 3. Mock callers and register them so the tracer expects real heralds
    c1 = spawn(fn -> :ok end)
    c2 = spawn(fn -> :ok end)
    c3 = spawn(fn -> :ok end)

    :mon_reg.set_mon(c1, self())
    :mon_reg.set_mon(c2, self())
    :mon_reg.set_mon(c3, self())

    # 4. Start the monitor for our worker
    {:ok, mon} = :ddtrace.start_link(worker_pid, [])

    # Mock Request IDs
    r1 = make_ref()
    r2 = make_ref()
    r3 = make_ref()

    # 5. Trace the ddt_detector to capture the exact order of Waitee additions
    :erlang.trace_pattern({:ddt_detector, :add_waitee, 3}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(mon, true, [:call])

    # =======================================================================
    # 6. Inject the adversarial sequence directly into the monitor's mailbox
    # =======================================================================

    # H3: Cast herald 3
    :gen_statem.cast(mon, {:"$ddt_herald", c3, {:"$ddt_query", r3}})
    :sys.get_state(mon) # Barrier after each to ensure ordering

    # T1: Raw Trace 1
    send(mon, {:trace, worker_pid, :receive, {:"$gen_call", {c1, r1}, :msg1}})
    :sys.get_state(mon) # Barrier after each to ensure ordering

    # T2: Raw Trace 2
    send(mon, {:trace, worker_pid, :receive, {:"$gen_call", {c2, r2}, :msg2}})
    :sys.get_state(mon) # Barrier after each to ensure ordering

    # H1: Cast herald 1
    :gen_statem.cast(mon, {:"$ddt_herald", c1, {:"$ddt_query", r1}})
    :sys.get_state(mon) # Barrier after each to ensure ordering

    # H2: Cast herald 2
    :gen_statem.cast(mon, {:"$ddt_herald", c2, {:"$ddt_query", r2}})
    :sys.get_state(mon) # Barrier after each to ensure ordering

    # T3: Raw Trace 3
    send(mon, {:trace, worker_pid, :receive, {:"$gen_call", {c3, r3}, :msg3}})

    # =======================================================================

    # 7. Synchronize to ensure all messages are processed.
    # :sys.get_state is a synchronous call. It will block until the mailbox is drained.
    assert {:synced, _data} = :sys.get_state(mon)

    # 8. Stop tracing
    :erlang.trace(mon, false, [:call])

    # 9. Collect the traced calls
    calls = collect_trace_calls([])

    # Extract the sequence of ReqIds passed to ddt_detector:add_waitee
    req_ids =
      calls
      |> Enum.filter(fn {m, f, _args} -> m == :ddt_detector and f == :add_waitee end)
      |> Enum.map(fn {_, _, [_who, req_id, _state]} -> req_id end)

    # Assertion: Despite the complex nested wait states and postponements,
    # the WFG state MUST be updated in the exact chronological order of the traces!
    # Before the fix, this evaluated as [r1, r3, r2].
    assert req_ids == [r1, r2, r3]
  end

  defp collect_trace_calls(acc) do
    receive do
      {:trace, _pid, :call, {m, f, args}} ->
        collect_trace_calls([{m, f, args} | acc])
      # Ignore the return_trace messages
      {:trace, _pid, :return_from, _mfa, _ret} ->
        collect_trace_calls(acc)
    after
      100 -> Enum.reverse(acc)
    end
  end
end
