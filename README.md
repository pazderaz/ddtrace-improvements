Markdown
# DDTrace

DDTrace is a tool for asynchronous distributed deadlock detection in
`gen_server`-based systems.

## Installation

As a standalone library, DDTrace can be added to your Elixir or Erlang projects as a dependency.

**For Elixir (`mix.exs`):**
```elixir
def deps do
  [
    {:ddtrace, github: "pazderaz/ddtrace-improvements"}
  ]
end
```

## Application requirements

The monitored system must entirely consist of `gen_server` instances. Moreover,
each server must adhere to _Single-threaded Remote Procedure Call_ (SRPC), which
in practice means that it may only use `gen_server:call` and `gen_server:cast`
for communication. To calls, they must always reply via `{reply, _Reply,
_State}` (i.e. no accumulation of the `From` argument and returning `{noreply,
_State}`). Multi-calls* through `gen_server:multi_call` and manual request
handling via `gen_server:send_request`/`gen_server:reply` is also forbidden. In
order for deadlock detection to work properly, every generic server must be
monitored.

TODO: there is a chance that `gen_server:multi_call` would work, but this is to be investigated.

### Tracing limitations

`ddtrace` monitors employ the `trace` facility to oversee their `gen_server` instances. 
Because Erlang allows at most one tracer for each process, this effectively prevents using
`trace` to debug systems monitored by `ddtrace`. 

## Instrumenting generic servers with DDTrace

A monitor is started via `ddtrace:start` or `ddtrace:start_link`. The PID of the
monitored `gen_server` is passed as a parameter.

Monitors recognise each other via a *monitor registry* which maps generic
servers' PIDs to their monitors. The registry is implemented in the `mon_reg`
module using `pg` process groups. Monitors take care of registering themselves
in the registry automatically.

In order to receive a deadlock notification, the user needs to register itself
as a subscriber to a particular monitor. One would normally subscribe to a
monitor immediately after making a call, and unsubscribe upon receiving a
response or deadlock notification. To subscribe to deadlocks, use the
`ddtrace:subscribe_deadlocks` function (use `ddtrace:unsubscribe_deadlocks` to opt out). The
subscribtion function returns a request identifier that can be used in generic
server's `reqid` or listened to directly via `gen_server:wait_response`.

The following snippet exemplifies how to monitor a single generic
server with DDTrace:

``` erlang
%% Start the service
{ok, P} = gen_server:start(my_gen_server_module, []),

%% Start the monitor
{ok, M} = ddtrace:start_link(P),

%% Subscribe to deadlocks
ReqM = ddtrace:subscribe_deadlocks(M),

%% Call the service
ReqP = gen_server:send_request(P, request)

%% Set up request ID collection
ReqIds0 = gen_server:reqids_new(),
ReqIds1 = gen_server:reqids_add(ReqP, process, ReqIds0),
ReqIds2 = gen_server:reqids_add(MonP, monitor, ReqIds1),

case gen_statem:receive_response(ReqIds2, infinity, true) of
  {{reply, R}, process, _ReqIds} -> %% Handle reply
  {{reply, {deadlock, Cycle}}, monitor, _ReqIds} -> %% Handle deadlock
end.
```
**IMPORTANT:** Self-inflicted deadlocks (e.g. `gen_server:call(self(), lol)`)
are handled by `gen_server` and cause the process to crash without sending a
call message. DDTrace will handle this case as well, but the end user might a
receive crash result before the deadlock notification from DDTrace. Note that
simply waiting for `{error, {calling_self, _}, _Label, _ReqIds}` is not
sufficient, as this may happen in a nested call. Therefore, some additional
recursion might be needed to distinguish such a deadlock from a regular error.

## Repository layout

This repository is structured to separate the core, distributable library from the academic and evaluation models used to test it. We provide a few example scenarios showcasing the functionality of DDTrace.  All are located in the `examples` directory with instructions on how to run them.

* `lib/` & `src/` – The core DDTrace library source code.
* `examples/` – The evaluation tools and simulations.
    * `model/` – The scenario generator, tracer tooling, and Elixir CLI used to exercise the library via configuration files.
    * `microchip_factory/` – An example `gen_server`-based Elixir application which shows DDTrace in a slightly more realistic local setup.
    * `elephant_patrol/` — An example *distributed* `gen_server`-based Elixir app simulating cross-node deadlock detection.

> **Note on Environment:** The `examples/` directory contains an `install-otp.sh` script to help configure the correct Erlang/Elixir versions via `asdf` for running the evaluations.


### 1. The Scenario Testing CLI (`model`)

To build the testing framework introduced in our [OOPSLA paper](https://doi.org/10.1145/3763069), refer to `examples/model/README.md`.

### 2. Microchip Factory Simulation

To run the local `gen_server` simulation, refer to the instructions in `examples/microchip_factory/README.md`.

### 3. Elephant Patrol Simulation

To run the distributed `gen_server` simulation across multiple nodes, refer to the instructions inside `examples/elephant_patrol/README.md`.

## Prerequisites

- Erlang/OTP 26
- Elixir 1.14