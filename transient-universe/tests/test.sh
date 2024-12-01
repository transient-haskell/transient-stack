runghc -DDEBUG  -w -i../src -i../../transient/src  flow.hs -p start/127.0.0.1/8001 < /dev/null  > 8001.ansi 2>&1 &
runghc -DDEBUG  -w -i../src -i../../transient/src  flow.hs -p start/127.0.0.1/8002  < /dev/null > 8002.ansi 2>&1 &
runghc -DDEBUG  -w -i../src -i../../transient/src  flow.hs -p start/127.0.0.1/8000/add/127.0.0.1/8001/n/add/127.0.0.1/8002/n/go  2>&1 | tee 8000.ansi
