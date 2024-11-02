currently testing transient-universe

cd transient-universe/tests

To compile every change and create the test programs in debug mode

cabal install -f debug test-transient1 --overwrite-policy=always

TO run the monitor in debug mode
runghc -w -i../src -i../../transient/src ../app/server/Transient/Move/Services/MonitorService.hs -p start/localhost/3000

To run te test suite in debug mode:
runghc -DDEBUG -w -i../src -i../../transient/src TestSuite.hs

See the logs
[text](transient-universe/tests/log/test-transient1--p-start-localhost-3002.log)


TO USE RUNGHC/GHCI when libraries are not found

repeat:
>cabal install library --lib  --package-env .

for each library that does not find

https://discourse.haskell.org/t/could-not-find-module-in-ghci/4385/9

packages to install:
random directory bytestring containers mtl stm bytestring aeson case-insensitive network websockets network-uri old-time base64-bytestring  network-uri network-bsd
