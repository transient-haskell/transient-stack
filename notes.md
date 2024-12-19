currently testing transient-universe

cd transient-universe/tests

To compile every change and create the test programs in debug mode

cabal install -f debug test-transient1 --overwrite-policy=always

TO run the monitor in debug mode
runghc -w -threaded -rtsopts  -i../src -i../../transient/src ../app/server/Transient/Move/Services/MonitorService.hs -p start/localhost/3000

To run te test suite in debug mode:
runghc -DDEBUG -w  -threaded -rtsopts  -i../src -i../../transient/src TestSuite.hs

See the logs
[text](transient-universe/tests/log/test-transient1--p-start-localhost-3002.log)


TO USE RUNGHC/GHCI when libraries are not found

repeat:
>cabal install --lib  --package-env . <library>

for each library that does not find

https://discourse.haskell.org/t/could-not-find-module-in-ghci/4385/9

packages to install:

cabal install  --lib  --package-env . random directory bytestring containers mtl stm bytestring aeson case-insensitive network websockets network-uri old-time base64-bytestring TCache data-default  network-uri network-bsd     text mime-types process vector TCache

for transient-universe-tls:   tls 


Para ejecutar con profile
ghcup install ghc 9.0
-- set path

usar transient-typelevel para una monad que incluya automaticamente local, onAll o id a cada término.

pero loggedc?

Ver que async ejecuta su argumento en un nuevo thread : si

test de TCache que salva un estado coherente: si

runAt service  que es una compilacion concreta del programa, con macros