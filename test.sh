#!/bin/bash

# On OS X, I had to use 127.0.0.1 rather than localhost when using
# the SimpleLocalnet backend; presumabwaily an IPv6 / UDP multicast issue?

stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 1 --host 127.0.0.1 --port 12341 &
stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 2 --host 127.0.0.1 --port 12342 &
stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 3 --host 127.0.0.1 --port 12343 &
stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 4 --host 127.0.0.1 --port 12344 &
stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 5 --host 127.0.0.1 --port 12345 &
stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 6 --host 127.0.0.1 --port 12346 &
stack exec iohk -- --send-for 10 --wait-for 5 --with-seed 7 --host 127.0.0.1 --port 12347 &

echo Running...
sleep 20
echo Done.
