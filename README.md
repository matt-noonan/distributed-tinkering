# Building the project

The command-line tool can be built by running

```bash
stack build
```

from the project's top-level directory.

# The idea

Each node $`n`$ in the network maintains a set of *seen* messages $`S_n`$, and a set of
*canonical* messages $`C_n`$. During the initial phase, all nodes send messages with
random payloads to each other, which are accumulated into the *seen* sets.

## The canonical message invariant

The *canonical* messages $`C_n`$ have the important invariant that
$`x \in C_n`$ if and only if $`x`$ is in $`C_m`$ for at least half of the nodes in the
network.
It follows that for any $`X \subseteq N`$ with $`|X| > \frac{|N|}{2}`$,

```math
\bigcup_{x \in X} C_x = \bigcup_{n \in N} C_n
```

This means that the union over any majority's canonical sets will give the same
value. We use this invariant in the final stage to report the same answer at every node,
by having each node "vote" for its own canonical set, and then waiting until
a majority of votes have been seen.

## Updating the canonical set

Periodically, a helper for node $`n`$ checks if $`S_n \setminus C_n`$ is non-empty.
If so, the helper initiates a *write request* to the network.

The write request includes the value $`S_n \setminus C_n`$. Nodes that receive the
write request respond with an `Ack` message to indicate their willingness to accept
the write. If the initiator of the write request receives `Ack` messages from a
majority of nodes, then it broadcasts a `Commit` message. This informs the nodes
that a quorum of `Ack`s was received and they should finalize the write. At that
time, the nodes insert $`S_n \setminus C_n`$ into their own canonical set.

## A bug in the protocol as implemented

The canonical set invariant can be violated if the `Commit` message from the
write requestor is not received by a majority of nodes. To ensure that the invariant
eventually holds, some mechanism should be put in place that allows us to
resend `Commit` messages until each node that `Ack`ed can verify that it responded
to the `Commit`. Because of this bug, it *can* happen that the invariant is
violated, causing different values to be reported at different nodes.

# Generalizations

This situation is similar to Paxos, but simpler in many ways. Partly, this
simplification comes from the fact that updates to the distributed state machine's
state all commute, so nodes do not need to worry about message sequencing.

# Test cases

A suite of tests that operate on a 7-node network under a variety of failure scenarios
can be run by executing

```bash
stack test
```