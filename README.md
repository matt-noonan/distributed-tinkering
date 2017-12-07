* Data messages

A data message contains the sender's node id N, a timestamp T,
and a random number 0 <= R <= 1.

Data messages are broadcast to all nodes.

* Worker state

Each worker maintains the following internal state:

  - The set of messages S received so far.
  - The "canonical" set C of messages agreed on with the other nodes.

From this, we can also derive the delta (G,K) between C and S, such that
S = (C \ K) + G. We can assume that G and K have an empty intersection.

The idea here is that each worker keeps track of the data messages it has seen,
and also works to create a consensus with other nodes about what the "correct"
set of messages is. 