defmodule Junction do
  @moduledoc """
  This module simulates a 4-way stop junction where each road can be in one of two states: :empty or :car_waiting.

  When a car arrives, it transitions from :empty to :car_waiting.
  When a car attempts to cross, it must first ask the road to its right for clearance.
  """

  require Logger

  @doc """
  This example simulates the same scenario as `run_deadlocked/0` but with randomized timings to demonstrate how a deadlock can occur in practice.
  """
  def run_simulation do
    start_roads()

    parent = self()

    # A single worker function representing the complete lifecycle of a car
    drive_car = fn road_name ->
      spawn(fn ->
        # 1. Randomize exactly when the car approaches the intersection
        Process.sleep(:rand.uniform(100))
        Road.arrive_async(road_name)

        # 2. Randomize the driver's reaction time before attempting to cross
        # Will they check their right before the car on their right has pulled up?
        Process.sleep(:rand.uniform(100))
        Road.attempt_cross(road_name)

        send(parent, {road_name, :success})
      end)
    end

    drive_car.(:north)
    drive_car.(:west)
    drive_car.(:south)
    drive_car.(:east)

    case collect_deadlocks() do
      0 ->
        Logger.info("Simulation concluded without deadlocks!")
      n ->
        Logger.warning("Simulation concluded with #{n} locked roads!")
    end
  end

  def arrive_sync(roads) do
    Enum.each(roads, &Road.arrive/1)
  end

  # Cross simultaneously, because sequential may result in a lock (the free car refuses to move),
  # then await all to finish before proceeding to the next phase.
  def cross_parallel_await(roads) do
    parent = self()
    Task.await_many(Enum.map(roads, fn road ->
      Task.async(fn ->
        Road.attempt_cross(road)
        # If we successfully cross, we send a message back to the parent process.
        send(parent, {road, :success})
      end)
    end))
  end

  # Cross simultaneously, because sequential may result in a lock (the free car refuses to move).
  def cross_parallel(roads) do
    parent = self()
    Enum.each(roads, fn road ->
      {:ok, _} = Task.start(fn ->
        Road.attempt_cross(road)
        # If we successfully cross, we send a message back to the parent process.
        send(parent, {road, :success})
      end)
    end)
  end

  def start_roads do
    Enum.each([
      {:north, :west},
      {:west, :south},
      {:south, :east},
      {:east, :north}
    ], fn {road, waitsFor} ->
      {:ok, pid} = Road.start_link(road, waitsFor)
      {:ok, monPid} = DDTrace.Registrar.register(pid)
      :ddtrace.subscribe_deadlocks(monPid)
    end)
  end

  def collect_deadlocks do
    receive do
      {_, {:deadlock, dl}} ->
        Logger.notice("Deadlock detected: #{inspect(dl)}!")
        collect_deadlocks() + 1
      {road, :success} ->
        Logger.info("Car crossed on: #{road}!")
        collect_deadlocks()
    after
      100 ->
        0
    end
  end
end
