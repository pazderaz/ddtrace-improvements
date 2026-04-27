defmodule SenderReceiverTest do
  use ExUnit.Case, async: false
  require Logger

  setup do
    for name <- [MonitoredReceiver, MonitoredSender] do
      if pid = Process.whereis(name), do: Process.exit(pid, :kill)
    end

    # 1. Start the actual worker processes
    {:ok, receiver} = MonitoredReceiver.start_link()
    {:ok, sender} = MonitoredSender.start_link()

    # 2. Attach ddtrace monitors to both.
    {:ok, mon_receiver} = DDTrace.Registrar.register(receiver)
    {:ok, mon_sender} = DDTrace.Registrar.register(sender)

    # Subscribe the current test process to deadlock notifications
    :ddtrace.subscribe_deadlocks(mon_receiver)
    :ddtrace.subscribe_deadlocks(mon_sender)

    on_exit(fn ->
      # Clean up processes after each test
      if Process.alive?(receiver), do: Process.exit(receiver, :kill)
      if Process.alive?(sender), do: Process.exit(sender, :kill)
    end)

    %{sender: sender, receiver: receiver, mon_sender: mon_sender, mon_receiver: mon_receiver}
  end

  test "detects simple circular deadlock when Sender and Receiver call each other", %{sender: sender_pid, receiver: receiver_pid} do
    Task.start(fn -> MonitoredSender.create_deadlock() end)

    assert_receive {_, {:deadlock, dl}}, 100

    assert sender_pid in dl
    assert receiver_pid in dl
  end

  test "recovers from a handled timeout and detects a subsequent deadlock", %{sender: sender_pid, receiver: receiver_pid} do
    # 1. Trigger a message that we know will timeout (Sender uses 10ms for this)
    assert {:error, :receiver_timeout} = MonitoredSender.send_ignored_message("This will time out")

    # 2. Verify the system is still functional after the timeout
    assert {:ok, _} = MonitoredSender.send_message("Testing recovery")

    # 3. Now trigger a real deadlock and ensure the monitor is still watching
    Task.start(fn -> MonitoredSender.create_deadlock() end)

    assert_receive {_, {:deadlock, dl}}, 100

    assert sender_pid in dl
    assert receiver_pid in dl
  end

  test "multiple timeouts result in no deadlocks" do
    {:error, :receiver_timeout} = MonitoredSender.send_ignored_message("This will time out")
    {:ok, _} = MonitoredSender.send_message("Testing recovery")
    {:error, :receiver_timeout} = MonitoredSender.send_ignored_message("This will also time out")

    {:error, :receiver_timeout} = MonitoredSender.send_ignored_message("Final time out")

    refute_receive {_, {:deadlock, _}}, 100
  end

  @tag :capture_log
  test "monitor shuts down via exit trapping", %{sender: s_pid, mon_sender: mon_pid} do
    Process.flag(:trap_exit, true)
    mon_monitor_ref = Process.monitor(mon_pid)

    spawn(fn -> MonitoredSender.send_crashing_timeout() end)

    assert_receive {:EXIT, ^s_pid, _reason}, 100
    assert_receive {:DOWN, ^mon_monitor_ref, :process, ^mon_pid, _}, 100

    Process.flag(:trap_exit, false)
  end

  test "normal message passing does not trigger deadlock notifications" do
    # Perform standard calls that return successfully
    for _ <- 1..10 do
      assert {:ok, _} = MonitoredSender.send_message("Ping")
    end

    # Ensure no deadlock message arrived in the mailbox
    refute_receive {_, {:deadlock, _}}, 100
  end

  test "late reply after timeout does not break monitor state", %{sender: s_pid, receiver: r_pid} do
    # Send message a message that times out after "delay". It will be replied to after: delay * 2
    delay = 10
    {:error, :receiver_timeout} = MonitoredSender.send_delayed_message(delay)

    # Give enough time to receive the late reply
    Process.sleep(delay * 2)

    # Check that we can still detect a deadlock
    Task.start(fn -> MonitoredSender.create_deadlock() end)

    assert_receive {_, {:deadlock, dl}}, 100

    assert s_pid in dl
    assert r_pid in dl
  end
end
