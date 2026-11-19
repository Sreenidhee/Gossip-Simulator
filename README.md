# Gossip Simulator

## How to run

You need Erlang installed (we used OTP 29). From inside this folder:

```sh
make
./project2 numNodes topology algorithm
```

topology is one of `full`, `2D`, `line`, `imp2D` and algorithm is `gossip` or
`push-sum`. For example:

```sh
./project2 1000 imp2D push-sum
```

The `project2` script also compiles the code by itself if `make` wasn't run.

Sample output:

```
Nodes: 1024 (requested 1000)  Topology: imp2D  Algorithm: push-sum
Setup time: 1.296 ms
Status: converged (1024/1024 actors)
True average: 512.500000  mean estimate: 512.500000  max relative error: 1.345e-11  (sum estimate 524800.000000)
Convergence time: 886375 microseconds (886.375 ms)
RESULT,1024,imp2D,push-sum,886375,converged,1024,512.5000000000,1.34516e-11
```

We time convergence with the `measure_running_time` function from the
assignment. The clock starts when the main process sends the first message and
stops when it sees that the algorithm has converged. Creating the actors is not
counted. For 2D and imp2D we round numNodes up to the next perfect square
(1000 becomes 1024). The last RESULT line is just there so our experiment script
can read the output.

## Files

- `src/project2.erl` - main program: reads the arguments, spawns the actors,
  starts the algorithm, waits for convergence and prints the time
- `src/gossip_node.erl` - the gossip actor
- `src/pushsum_node.erl` - the push-sum actor
- `src/topology.erl` - the four topologies and picking a random neighbour
- `experiments/` - our Erlang scripts for running the experiments
  (`run_experiments.escript`) and drawing the graphs (`make_report.escript`),
  the results (`results_base.csv`) and the report page (`report_base.html`)

Every node is a separate Erlang process and they only talk through messages.
Each actor has a number from 1 to N and keeps its neighbours as numbers, not
PIDs. The PIDs are stored once in a tuple in `persistent_term` that every actor
can read. We did this because in the full network every actor would otherwise
need a list of all N PIDs, and that runs out of memory quickly. In imp2D each
actor picks its extra random neighbour when it starts.

## What is working

Everything: all four topologies with both algorithms.

### Gossip

When an actor hears the rumor for the first time it lets the main process know
and starts spreading it. Every 1 ms it picks a random neighbour and tells it the
rumor. After hearing the rumor 10 times it stops. We count the network as
converged once every actor has heard the rumor at least once.

Two things we added:

- If a stopped actor gets the rumor again it replies "done", and the sender
  takes it out of its neighbour list. If an actor runs out of neighbours it
  stops too. Without this the line got stuck a lot, because actors kept
  sending to neighbours that had already stopped.
- The 1 ms timer. Our first version had each actor send a message to itself
  to trigger the next send, so it sent as fast as it could. That turned out to
  be a problem: one actor could push dozens of rumors into its neighbour's
  mailbox before the neighbour got to run. The neighbour then counted to 10
  and stopped before it ever passed the rumor on. On the line the rumor died
  after about 3 actors. With the timer every actor sends roughly once per
  "round" and this went away.

### Push-Sum

Done the way the assignment describes it. Actor i starts with s = i and w = 1.
The main process tells one actor to start. Whenever an actor receives a pair it
adds it to its own s and w, keeps half and sends the other half to a random
neighbour. It terminates when s/w has changed by less than 10^-10 in 3
receives in a row. We count the network as converged once every actor has
terminated, and we print the real average, the average of all the estimates and
the worst error.

Since w starts at 1 everywhere, s/w ends up at the average of the values, not
the sum. To get the sum you multiply by N, which we print as "sum estimate".

An actor that has already terminated still forwards any pair it gets to a
random neighbour, so the message can still reach actors that haven't finished.

At first we tried a version where every actor sent on its own timer instead
of only when it received something. It didn't work well. Two neighbours would
often send to each other at the same time, end up with exactly the same s and
w, and from then on the 3-round rule was satisfied right away. Errors were
around 80% on the 2D grid. With the receive-driven version there is only one
message moving around at a time and this doesn't happen.

### Problems we know about

- Push-sum on the line finishes but the answer is not accurate. The worst
  actor is off by 2% with 100 nodes and by 76% with 1000. On a line,
  neighbouring actors have almost the same value, so the "no change in 3
  rounds" rule is met long before values from the other end of the line have
  arrived. On the other three topologies the error is below 10^-6.
- With the 10-times rule, gossip can very rarely miss an actor: all of its
  neighbours hear the rumor 10 times and stop before any of them happens to
  pick it. We saw this twice, both on imp2D: once at 300k nodes (300,303 out
  of 300,304 reached) and once at 1M (999,998 out of 1,000,000). In that case
  the program prints "stalled" and how many actors were reached, instead of
  waiting forever.

## Largest network we managed to deal with

All of this was run on an 8-core MacBook Air with 8 GB of RAM. For 2D and imp2D
the sizes are after rounding up to a square.

| Topology | Gossip | Push-Sum |
|----------|--------|----------|
| Full     | 1,000,000 (134 s) | 300,000 (481 s) |
| 2D       | 300,304 (2.9 s) | 10,000 (378 s) |
| Line     | 100,000 (293 s) | 3,000 (50 s, but the error was 97%, see above) |
| imp2D    | 300,304 (2.9 s) | 100,489 (56 s) |

imp2D gossip at 1,000,000 nodes reached 999,998 of the actors in 85 s, so we
didn't count it as fully converged. We didn't try larger sizes because either
the runs went over our 15 minute limit (push-sum on 2D and line) or the laptop
started running out of memory (around 1M actors).

## Experiments

```sh
escript experiments/run_experiments.escript base
```

This runs all the sizes for every topology and algorithm, one run at a time.
Each size is repeated 3 times if a run takes less than 30 s, otherwise once,
and a topology stops getting bigger once a run goes over 15 minutes. Everything
is saved to `experiments/results_base.csv`.

```sh
escript experiments/make_report.escript base
```

This reads the CSV file, draws the graphs as SVG files (in
`experiments/figures/`), puts them into `report_base.html` and prints it to
Report.pdf with Google Chrome.
