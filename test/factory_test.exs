defmodule FactoryTest do
  use ExUnit.Case

  test "(monitored) small microchip factory never times out" do
    refute MicrochipFactory.start_two(true, false) == :timeout
  end

  test "(monitored) complex microchip factory never times out" do
    refute MicrochipFactory.start_many(true, false) == :timeout
  end
end
