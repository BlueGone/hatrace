{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module HatraceSpec where

import           Control.Monad (when)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as BS
import           Data.Conduit
import qualified Data.Conduit.Combinators as CC
import qualified Data.Conduit.List as CL
import           Data.Set (Set)
import qualified Data.Set as Set
import           System.Directory (doesFileExist, removeFile)
import           System.Exit
import           System.Posix.Files (getFileStatus, fileSize)
import           System.Posix.Signals (sigTERM)
import           System.Process (callProcess)
import           Test.Hspec

import System.Hatrace


-- | Assertion we run before each test to ensure no leftover child processes
-- that could affect subsequent tests.
--
-- This is obviously not effective if tests were to run in parallel.
assertNoChildren :: IO ()
assertNoChildren = do
  hasChildren <- doesProcessHaveChildren
  when hasChildren $ do
    error "You have children you don't know of, probably from a previous test"


spec :: Spec
spec = before_ assertNoChildren $ do
  -- Note we use `before_` instead of `after_` above because apparently,
  -- hspec swallows test failure messages if after the test faulure the
  -- `after_` action fails as well, showing only the latter's message.

  describe "traceCreateProcess" $ do

    it "does not crash for this echo process" $ do
      traceForkProcess "echo" ["hello"] `shouldReturn` ExitSuccess

    -- TODO Instead of compiling things here with `make`, do it as a Cabal hook.

    it "does not crash for hello.asm with 32-bit API" $ do
      callProcess "make" ["--quiet", "example-programs-build/hello-linux-i386-elf64"]
      traceForkProcess "example-programs-build/hello-linux-i386-elf64" [] `shouldReturn` ExitSuccess

    it "does not crash for hello.asm real 32-bit" $ do
      callProcess "make" ["--quiet", "example-programs-build/hello-linux-i386"]
      traceForkProcess "example-programs-build/hello-linux-i386" [] `shouldReturn` ExitSuccess

    it "does not crash for hello.asm with 64-bit API" $ do
      callProcess "make" ["--quiet", "example-programs-build/hello-linux-x86_64"]
      traceForkProcess "example-programs-build/hello-linux-x86_64" [] `shouldReturn` ExitSuccess

    it "does not hang when the traced program segfaults" $ do
      callProcess "make" ["--quiet", "example-programs-build/segfault"]
      traceForkProcess "example-programs-build/segfault" [] `shouldReturn` ExitFailure 139

  describe "sourceTraceForkExecvFullPathWithSink" $ do

    it "lets the process finish if the sink exits early" $ do
      argv <- procToArgv "echo" ["hello"]
      (exitCode, ()) <- sourceTraceForkExecvFullPathWithSink argv (return ())
      exitCode `shouldBe` ExitSuccess

    it "allows obtaining all syscalls as a list for hello.asm" $ do
      callProcess "make" ["--quiet", "example-programs-build/hello-linux-x86_64"]
      argv <- procToArgv "example-programs-build/hello-linux-x86_64" []
      (exitCode, events) <- sourceTraceForkExecvFullPathWithSink argv CL.consume

      let syscalls = [ syscall | (_pid, SyscallStop (SyscallEnter (syscall, _args))) <- events ]
      exitCode `shouldBe` ExitSuccess
      syscalls `shouldBe`
        [ KnownSyscall Syscall_execve
        , KnownSyscall Syscall_write
        , KnownSyscall Syscall_exit
        ]

    describe "subprocess tracing" $ do

      it "can trace 'bash -c ./hello'" $ do
        callProcess "make" ["--quiet", "example-programs-build/hello-linux-x86_64"]
        -- We must run *something* (e.g. `true &&`) before the program,
        -- otherwise bash will just execve() and not fork() at all, in which case
        -- this test wouldn't actually test tracing into subprocesses.
        argv <- procToArgv "bash" ["-c", "true && example-programs-build/hello-linux-x86_64"]
        (exitCode, events) <- sourceTraceForkExecvFullPathWithSink argv CL.consume
        let cloneWriteSyscalls =
              [ syscall
              | (_pid, SyscallStop (SyscallEnter (KnownSyscall syscall, _args))) <- events
              , syscall `elem` [Syscall_clone, Syscall_write]
              ]
        exitCode `shouldBe` ExitSuccess
        cloneWriteSyscalls `shouldBe` [Syscall_clone, Syscall_write]

      it "can handle the situation that the child doesn't wait for its children" $ do
        pendingWith "implement test with simple C program that doens't wait for a child"

      it "can handle the situation that a child's child double-forks" $ do
        pendingWith "implement test with simple C program that has a child double-fork"

      it "can handle Group-stop in multithreaded programs" $ do
        pendingWith "implement test with simple C program that uses multiple threads"

  describe "program inspection" $ do

    it "can point out that the difference in syscalls between atomic and non-atomic write is a rename" $ do

      callProcess "make" ["--quiet", "example-programs-build/atomic-write"]
      let getSyscallsSetFor :: [String] -> IO (Set Syscall)
          getSyscallsSetFor args = do
            argv <- procToArgv "example-programs-build/atomic-write" args
            (exitCode, events) <- sourceTraceForkExecvFullPathWithSink argv CL.consume
            let syscalls = [ syscall | (_pid, SyscallStop (SyscallEnter (syscall, _args))) <- events ]
            exitCode `shouldBe` ExitSuccess
            return (Set.fromList syscalls)

      -- Don't pick this it too large, because `atomic-write` writes only
      -- 1 character per syscall, and ptrace() makes syscalls slow.
      let numBytes = 100 :: Int
      syscallsAtomic <- getSyscallsSetFor ["atomic", show numBytes, "example-programs-build/testfile"]
      syscallsNonAtomic <- getSyscallsSetFor ["non-atomic", show numBytes, "example-programs-build/testfile"]

      let differenceInSyscalls = syscallsAtomic `Set.difference` syscallsNonAtomic

      differenceInSyscalls `shouldBe` Set.fromList [KnownSyscall Syscall_rename]

  describe "program misbehaviour detection" $ do

    it "can show that SIGTERM at the right time results in cut-off files for non-atomically writing programs" $ do

      let targetFile = "example-programs-build/testfile-for-sigterm"

      let killAfter3Writes :: String -> IO ()
          killAfter3Writes atomicityFlag = do
            callProcess "make" ["--quiet", "example-programs-build/atomic-write"]
            let numBytes = 100 :: Int
            argv <- procToArgv "example-programs-build/atomic-write" [atomicityFlag, show numBytes, targetFile]

            let isWrite (_pid, SyscallStop (SyscallEnter (KnownSyscall Syscall_write, _args))) = True
                isWrite _ = False

            -- We have to use SIGTERM and cannot use SIGKILL as of writing,
            -- because Hatrace cannot yet handle the case where the tracee
            -- instantly goes away: we get in that case:
            --     ptrace: does not exist (No such process)
            -- For showing the below, SIGTERM is good enough for now.
            let killConduit =
                  awaitForever $ \(pid, _) -> liftIO $ sendSignal pid sigTERM

                -- Filters away everything that's not a write syscall,
                -- and at the onset of the 4th write, SIGTERMs the process.
                killAt4thWriteConduit =
                  CC.filter isWrite .| (CC.drop 3 >> killConduit)

            _ <- sourceTraceForkExecvFullPathWithSink argv killAt4thWriteConduit

            return ()

      -- Writing the file non-atomically should result in truncated contents.
      -- There should be 3 'a's in the file, as we killed after 3 writes.
      killAfter3Writes "non-atomic"
      fileContents <- BS.readFile targetFile
      fileContents `shouldBe` "aaa"

      removeFile targetFile

      -- Writing the file atomically should result in it not existing at all.
      killAfter3Writes "atomic"
      targetExists <- doesFileExist targetFile
      targetExists `shouldBe` False

    it "can be used to check whether GHC writes truncated object files or executables" $ do

      let targetFile = "example-programs-build/haskell-hello"
      let program = "ghc"
      let args =
            [ "--make"
            -- TODO enable this once we kill when writing the desired files (see TODO below)
            -- , "-fforce-recomp"
            , "-outputdir", "example-programs-build/"
            , "example-programs/Hello.hs"
            , "-o", targetFile
            ]

      let runGhcMake :: IO ()
          runGhcMake = do
            argv <- procToArgv program args

            let isWrite (_pid, SyscallStop (SyscallEnter (KnownSyscall Syscall_write, _args))) = True
                isWrite _ = False

            -- We have to use SIGTERM and cannot use SIGKILL as of writing,
            -- because Hatrace cannot yet handle the case where the tracee
            -- instantly goes away: we get in that case:
            --     ptrace: does not exist (No such process)
            -- For showing the below, SIGTERM is good enough for now.
            let killConduit =
                  -- TODO: Actually do the kill
                  -- awaitForever $ \(pid, _) -> liftIO $ sendSignal pid sigTERM
                  return ()

                -- Filters away everything that's not a write syscall,
                -- and at the onset of the 4th write, SIGTERMs the process.
                killAt4thWriteConduit =
                  -- TODO: Do the kill after some writes on `.o` files, not just any FDs
                  CC.filter isWrite .| (CC.drop 3 >> killConduit)

            (exitCode, ()) <-
              sourceTraceForkExecvFullPathWithSink argv (printSyscallOrSignalNameConduit .| killAt4thWriteConduit)
            exitCode `shouldBe` ExitSuccess

      -- Delete potentially leftover files from previous build
      callProcess "rm" ["-f", targetFile, "example-programs-build/Main.hi", "example-programs-build/Main.o"]

      -- Build normally, record output file size
      callProcess program args
      expectedSize <- fileSize <$> getFileStatus targetFile

      -- Build with kill
      runGhcMake

      -- Build normally, check if results are normal
      callProcess program args
      rebuildSize <- fileSize <$> getFileStatus targetFile
      rebuildSize `shouldBe` expectedSize

    it "can be used to check whether programs handle EINTR correctly" $ do
      pendingWith "implement test that uses PTRACE_INTERRUPT in every syscall"

  describe "per-syscall tests" $ do

    describe "read" $ do

      it "has the right output for 'echo hello | cat'" $ do
        argv <- procToArgv "bash" ["-c", "echo hello | cat > /dev/null"]
        (exitCode, events) <-
          sourceTraceForkExecvFullPathWithSink argv $
            syscallExitDetailsOnlyConduit .| CL.consume
        let stdinReads =
              [ bufContents
              | (_pid
                , DetailedSyscallExit_read
                    SyscallExitDetails_read
                      { enterDetail = SyscallEnterDetails_read{ fd = 0 }
                      , bufContents
                      }
                ) <- events
              ]
        exitCode `shouldBe` ExitSuccess
        -- Concatenate because there may be short reads and retries.
        BS.concat stdinReads `shouldBe` "hello\n"
