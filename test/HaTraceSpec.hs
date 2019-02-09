module HaTraceSpec where

import System.Exit
import System.Process (callProcess)
import Test.Hspec

import HaTrace

spec :: Spec
spec =
    describe "traceCreateProcess" $ do

        it "does not crash for this echo process" $ do
            traceForkExec ["echo", "hello"] `shouldReturn` ExitSuccess

        it "does not crash for this sleep process" $ do
            traceForkExec ["sleep", "1"] `shouldReturn` ExitSuccess

        it "does not crash for hello.asm" $ do
            -- TODO Instead of compiling here, do it as a Cabal hook.
            callProcess "make" ["--quiet", "example-programs/hello"]
            traceForkExec ["example-programs/hello"] `shouldReturn` ExitSuccess
