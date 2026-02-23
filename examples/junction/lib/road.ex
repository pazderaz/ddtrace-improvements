defmodule Road do
  @moduledoc """
  A 4-way stop road that transitions between :empty and :car_waiting.

  When a car arrives, it transitions from :empty to :car_waiting.
  When a car attempts to cross, it must first ask the road to its right for clearance.

  If the right road is also waiting, a deadlock can occur.
  """
  use GenStateMachine, callback_mode: :handle_event_function
  require Logger

  # --- API ---

  def start_link(road_name, right_road_name) do
    GenStateMachine.start_link(__MODULE__, right_road_name, name: road_name)
  end

  def arrive(road_name), do: GenStateMachine.call(road_name, :arrive)

  def arrive_async(road_name), do: GenStateMachine.cast(road_name, :arrive)

  def attempt_cross(road_name), do: GenStateMachine.call(road_name, :attempt_cross)

  def request_clearance(road_name), do: GenStateMachine.call(road_name, :request_clearance)

  # --- GenStateMachine Callbacks ---

  @impl GenStateMachine
  def init(right_road_name) do
    DDTrace.Registrar.register_me()
    {:ok, :empty, right_road_name}
  end

  # ==========================================
  # STATE: :empty
  # ==========================================

  # A car arrives at an empty road. We change state!
  @impl GenStateMachine
  def handle_event({:call, from}, :arrive, :empty, right_road_name) do
    {:next_state, :car_waiting, right_road_name, [{:reply, from, :ready}]}
  end

  # A car arrives asynchronously. We change state but DO NOT reply.
  def handle_event(:cast, :arrive, :empty, right_road_name) do
    {:next_state, :car_waiting, right_road_name}
  end

  # Someone asks for clearance while we are empty. We grant it immediately.
  def handle_event({:call, from}, :request_clearance, :empty, _right_road_name) do
    {:keep_state_and_data, [{:reply, from, :clear}]}
  end

  # ==========================================
  # STATE: :car_waiting
  # ==========================================

  # If another car arrives asynchronously while one is already waiting, we just ignore it.
  def handle_event(:cast, :arrive, :car_waiting, _right_road_name) do
    :keep_state_and_data
  end

  # The car at our road wants to cross.
  def handle_event({:call, from}, :attempt_cross, :car_waiting, right_road_name) do
    # Synchronous call to the right road. Blocks execution.
    :clear = GenStateMachine.call(right_road_name, :request_clearance)

    # If it returns, we cross and go back to :empty.
    {:next_state, :empty, right_road_name, [{:reply, from, :crossed}]}
  end

  # Someone asks for clearance, BUT we also have a car waiting!
  # Rule of the road: We yield to the right. We must check our right before we can answer.
  def handle_event({:call, from}, :request_clearance, :car_waiting, right_road_name) do
    # This right here is what dynamically builds the Wait-For Graph cycle!
    :clear = GenStateMachine.call(right_road_name, :request_clearance)

    # We only reply clear to the road on our left AFTER the road on our right clears us.
    {:keep_state_and_data, [{:reply, from, :clear}]}
  end
end
