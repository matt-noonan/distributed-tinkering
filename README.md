* The idea

Each node $`n`$ in the network maintains a set of *seen* messages $`S_n`$, and a set of
*canonical* messages $`C_n`$. During the initial phase, all nodes send messages with
random payloads to each other, which are accumulated into the *seen* sets.

The *canonical* messages $`C_n`$ have the important invariant that
$`x \in C_n`$ if and only if $`x`$ is in $`C_m`$ for at least half of the nodes in the
network.
It follows that for any $`X \subseteq N`$ with $`|X| > \frac{|N|}{2}`$,

```math
\bigcup_{x \in X} C_x = \bigcup_{n \in N} C_n
```

Periodically, a helper checks if $`S_k \setminus C_k`$ is non-empty. If so, 