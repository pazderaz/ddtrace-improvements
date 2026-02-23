defmodule Junction do

  require Logger

  @doc """
  This example simulates a 4-way stop junction where each road can be in one of two states: :empty or :car_waiting.

  When a car arrives, it transitions from :empty to :car_waiting.
  When a car attempts to cross, it must first ask the road to its right for clearance.
  """
  def run_deadlocked do
    {:ok, _} = Road.start_link(:north, :west)
    {:ok, _} = Road.start_link(:west, :south)
    {:ok, _} = Road.start_link(:south, :east)
    {:ok, _} = Road.start_link(:east, :north)

    # Phase 1: All cars pull up.
    # All 4 state machines successfully transition from :empty to :car_waiting.
    Road.arrive(:north)
    Road.arrive(:west)
    Road.arrive(:south)
    Road.arrive(:east)

    parent = self()

    # Phase 2: Everyone attempts to cross simultaneously.
    # Because everyone is in :car_waiting, they all recursively ask the road
    # to their right for clearance, building the WFG cycle instantly.
    attempt_to_cross = fn road_name ->
      spawn(fn ->
        Road.attempt_cross(road_name)
        send(parent, {road_name, :success})
      end)
    end

    attempt_to_cross.(:north)
    attempt_to_cross.(:west)
    attempt_to_cross.(:south)
    attempt_to_cross.(:east)

    # Phase 3: Validation
    receive do
      {road, :success} -> Logger.info("Car crossed on: #{road}! (Should not happen in this case)")
    after
      1000 -> Logger.info("Timeout detected! No car crossed the junction.")
    end
  end

  @doc """
  This example simulates the same scenario as `run_deadlocked/0` but with randomized timings to demonstrate how a deadlock can occur in practice.
  """
  def run_simulation do
    {:ok, _} = Road.start_link(:north, :west)
    {:ok, _} = Road.start_link(:west, :south)
    {:ok, _} = Road.start_link(:south, :east)
    {:ok, _} = Road.start_link(:east, :north)

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

    # Phase 3: Validation
    receive do
      {road, :success} -> Logger.info("Car crossed on: #{road}!")
    after
      1000 -> Logger.info("Timeout! No car crossed the junction.")
    end
  end
end
