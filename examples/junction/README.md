# Junction: A 4-Way Stop Deadlock Simulator

This example is a deterministic and probabilistic deadlock simulator built in Elixir using `GenStateMachine`.

## The Scenario

The simulation models a standard 4-way stop intersection with four distinct road processes: `:north`, `:west`, `:south`, and `:east`. 

Each road operates as a state machine with two states:
1. `:empty`
2. `:car_waiting`

The golden rule of the intersection is: **Yield to the right.**
* North yields to West.
* West yields to South.
* South yields to East.
* East yields to North.

### How the Deadlock Forms

Because this system adheres to strict SRPC rules, processes cannot defer replies or handle other messages while waiting for a call to return. If a road is in the `:car_waiting` state and is asked for clearance, it must synchronously call the road to its right to check *its* clearance before replying.

If four cars arrive at all four roads simultaneously, they all enter the `:car_waiting` state. When they attempt to cross, they recursively call the road to their right. This instantly creates a perfect circular **Wait-For Graph (WFG) cycle**, freezing all four execution threads indefinitely.

## Running the Simulations

You can execute the simulations directly from your terminal using `mix run`. The module provides two different execution modes:

### 1. The Race Condition (Probabilistic)

This mode introduces randomized jitter (`Process.sleep/1`) to simulate a real-world distributed system. Cars arrive asynchronously (`cast`) and attempt to cross at random intervals. 

Depending on the Erlang scheduler and the random delays, the traffic might flow perfectly, or the timing might align perfectly to trigger a deadlock.

**Command:**
`mix run -e "Junction.run_simulation()"`

**Expected Output:** You will see a mix of successful crossings and timeout warnings depending on how the race condition resolves on that specific run.

### 2. The Guaranteed Deadlock (Deterministic)

This mode is used to guarantee a WFG cycle for testing purposes. It forces all four roads into the `:car_waiting` state synchronously, and then triggers the crossing attempts concurrently. The intersection will deadlock 100% of the time.

**Command:**
`mix run -e "Junction.run_deadlocked()"`

**Expected Output:**
`[info]  Timeout detected! No car crossed the junction.`
