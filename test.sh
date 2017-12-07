#!/bin/bash

# On OS X, I had to use 127.0.0.1 rather than localhost when using
# the SimpleLocalnet backend; presumably an IPv6 / UDP multicast issue?

stack exec iohk -- --send-for 5 --wait-for 5 --with-seed 1 --host 127.0.0.1 --port 12341 &
stack exec iohk -- --send-for 5 --wait-for 5 --with-seed 2 --host 127.0.0.1 --port 12342 &
stack exec iohk -- --send-for 5 --wait-for 5 --with-seed 3 --host 127.0.0.1 --port 12343 &
stack exec iohk -- --send-for 5 --wait-for 5 --with-seed 4 --host 127.0.0.1 --port 12344 &
stack exec iohk -- --send-for 5 --wait-for 5 --with-seed 5 --host 127.0.0.1 --port 12345 &
