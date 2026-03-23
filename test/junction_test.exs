defmodule JunctionTest do
  use ExUnit.Case

  test "always deadlocked (cars arrive at the same time)" do
    Junction.start_roads()

    # All 4 state machines successfully transition from :empty to :car_waiting.
    Junction.arrive_sync([:north, :west, :south, :east])
    # Then try to cross simultaneously, but no car can cross.
    Junction.cross_parallel([:north, :west, :south, :east])

    assert Junction.collect_deadlocks() == 4
  end

  test "never deadlocked (cars arrive in a staggered manner)" do
    Junction.start_roads()

    Junction.arrive_sync([:north, :south])
    Junction.cross_parallel_await([:north, :south])

    Junction.arrive_sync([:west, :east])
    Junction.cross_parallel_await([:east, :west])

    Junction.arrive_sync([:west, :north, :east])
    Junction.cross_parallel_await([:east, :north, :west])

    Junction.arrive_sync([:west, :south, :east])
    Junction.cross_parallel_await([:east, :south, :west])

    assert Junction.collect_deadlocks() == 0
  end
end
