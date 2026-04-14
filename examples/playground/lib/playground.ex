defmodule Playground do

  require Logger

  def test_timeouts do
    {:ok, _} = Receiver.start()
    {:ok, _} = Sender.start()

    {status, reply} = Sender.send_ignored_message("Hello, Receiver!")
    Logger.info("Received <#{status}> reply: #{reply}")

    Process.sleep(2000)

    {status, reply} = Sender.send_message("Hello, Receiver!")
    Logger.info("Received <#{status}> reply: #{reply}")

    Process.sleep(1000)

    # {status, reply} = Sender.create_deadlock()
    # Logger.info("Received <#{status}> reply: #{reply}")

    Process.sleep(1000)
  end

  def test_repeated_call do
    {:ok, _} = Receiver.start()
    {:ok, _} = Sender.start()

    {status, reply} = Sender.send_message("Hello, Receiver!")
    Logger.info("Received <#{status}> reply: #{reply}")

    Process.sleep(1000)

    {status, reply} = Sender.send_message("Hello, Receier!")
    Logger.info("Received <#{status}> reply: #{reply}")

    Process.sleep(2000)
  end
end
