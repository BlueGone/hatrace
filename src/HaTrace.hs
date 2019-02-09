{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module HaTrace
  ( traceForkProcess
  , traceForkExecvFullPath
  , forkExecvWithPtrace
  ) where

import           Data.Bits ((.|.))
import           Data.List (find, genericLength)
import           Data.Word (Word32, Word64)
import           Foreign.C.Error (throwErrnoIfMinus1)
import           Foreign.C.Types (CInt(..), CChar(..))
import           Foreign.Marshal.Array (withArray)
import           Foreign.Marshal.Utils (withMany)
import           Foreign.Ptr (Ptr, wordPtrToPtr)
import           GHC.Stack (HasCallStack)
import           System.Directory (doesFileExist, findExecutable)
import           System.Exit (ExitCode(..), die)
import           System.Linux.Ptrace (TracedProcess(..), peekBytes)
import           System.Linux.Ptrace.Syscall
import           System.Linux.Ptrace.Types (Regs(..))
import           System.Linux.Ptrace.X86_64Regs (X86_64Regs(..))
import           System.Linux.Ptrace.X86Regs (X86Regs(..))
import           System.Posix.Internals (withFilePath)
import           System.Posix.Signals (Signal, sigTRAP, sigSTOP)
import qualified System.Posix.Signals as Signals
import           System.Posix.Types (CPid(..))
import           System.Posix.Waitpid (waitpid, Status(..))


waitpidForExactPidOrError :: (HasCallStack) => CPid -> IO ()
waitpidForExactPidOrError pid = do
  mr <- waitpid pid []
  case mr of
    Nothing -> error "forkExecvWithPtrace: BUG: no PID was returned by waitpid"
    Just (returnedPid, status)
      | returnedPid /= pid -> error $ "forkExecvWithPtrace: BUG: returned PID != expected pid: " ++ show (returnedPid, pid)
      | otherwise ->
        case status of
          Stopped sig | sig == sigSTOP -> return () -- all OK
          _ -> error $ "forkExecvWithPtrace: BUG: unexpected status: " ++ show status


foreign import ccall safe "fork_exec_with_ptrace" c_fork_exec_with_ptrace :: CInt -> Ptr (Ptr CChar) -> IO CPid


-- | Forks a tracee process, makes it PTRACE_TRACEME and then SIGSTOP itself.
-- Waits for the tracee process to have entered the STOPPED state.
-- After waking up from the stop (as controlled by the tracer, that is,
-- other functions you'll use after calling this one),
-- the tracee will execv() the given program with arguments.
--
-- Since execv() is used, the first argument must be the /full path/
-- to the executable.
forkExecvWithPtrace :: (HasCallStack) => [String] -> IO CPid
forkExecvWithPtrace args = do
  childPid <- withMany withFilePath args $ \cstrs -> do
    withArray cstrs $ \argsPtr -> do
      let argc = genericLength args
      throwErrnoIfMinus1 "fork_exec_with_ptrace" $ c_fork_exec_with_ptrace argc argsPtr
  -- Wait for the tracee to stop itself
  waitpidForExactPidOrError childPid
  return childPid


-- TODO Make a version of this that takes a CreateProcess.
--      Note that `System.Linux.Ptrace.traceProcess` isn't good enough,
--      because it is racy:
--      It uses PTHREAD_ATTACH, which sends SIGSTOP to the started
--      process. By that time, the process may already have exited.

traceForkExecvFullPath :: [String] -> IO ExitCode
traceForkExecvFullPath args = do
  childPid <- forkExecvWithPtrace args
  -- Set `PTRACE_O_TRACESYSGOOD` to make it easy for the tracer
  -- to distinguish normal traps from those caused by a syscall.
  ptrace_setoptions childPid [TraceSysGood]
  let loop state = do
        (newState, exitOrStop) <- waitForSyscall childPid state
        case exitOrStop of
          Left exitCode -> pure exitCode
          Right stopType -> do
            case stopType of
              SyscallStop SyscallEnter -> do
                syscall <- getEnteredSyscall childPid
                putStrLn $ "Entering syscall: " ++ show syscall
              SyscallStop SyscallExit -> do
                putStrLn $ "Exited syscall"
              SignalDeliveryStop sig -> do
                printSignal sig
            loop newState
  loop initialTraceState


traceForkProcess :: (HasCallStack) => FilePath -> [String] -> IO ExitCode
traceForkProcess name args = do
  exists <- doesFileExist name
  path <- if
    | exists -> pure name
    | otherwise -> do
      mbExe <- findExecutable "echo"
      case mbExe of
        Nothing -> die $ "Cannot find executable: " ++ name
        Just path -> pure path
  traceForkExecvFullPath (path:args)


-- | The terminology in here is oriented on `man 2 ptrace`.
data SyscallStopType = SyscallEnter | SyscallExit
  deriving (Eq, Ord, Show)


-- | The terminology in here is oriented on `man 2 ptrace`.
data StopType
  = SyscallStop SyscallStopType
  | SignalDeliveryStop Signal
  deriving (Eq, Ord, Show)


-- | Entering and exiting syscalls always happens in turns;
-- we must keep track of that.
--
-- As per `man 2 ptrace`:
--
-- > Syscall-enter-stop and syscall-exit-stop are indistinguishable from each
-- > other by the tracer.
-- > The tracer needs to keep track of the sequence of ptrace-stops in order
-- > to not misinterpret syscall-enter-stop as syscall-exit-stop or vice versa.
-- > The rule is that syscall-enter-stop is always followed by syscall-exit-stop,
-- > PTRACE_EVENT stop or the tracee's death; no other kinds of ptrace-stop
-- > can occur in between.
-- >
-- > If after syscall-enter-stop, the tracer uses a restarting command other than
-- > PTRACE_SYSCALL, syscall-exit-stop is not generated.
--
-- We use this data structure to track it.
data TraceState = TraceState
  { inSyscall :: !Bool -- ^ must be set to false if it's true and the next @ptrace()@ invocation is not @PTRACE_SYSCALL@
  } deriving (Eq, Ord, Show)


initialTraceState :: TraceState
initialTraceState =
  TraceState
    { inSyscall = False
    }


waitForSyscall :: (HasCallStack) => CPid -> TraceState -> IO (TraceState, Either ExitCode StopType)
waitForSyscall pid state@TraceState{ inSyscall } = do
  ptrace_syscall pid Nothing
  mr <- waitpid pid []
  case mr of
    Nothing -> error "waitForSyscall: no PID was returned by waitpid"
    Just (_returnedPid, status) -> do -- TODO must we have different logic if any other pid (e.g. thread, child process of traced process) was returned?
      -- What event occurred; loop if not a syscall or signal
      (newState, exitOrStop) <- case status of
        Exited i -> do
          case i of
            0 -> pure (state, Left ExitSuccess)
            _ -> pure (state, Left $ ExitFailure i)
        Continued -> waitForSyscall pid state
        Signaled sig -> pure (state, Right $ SignalDeliveryStop sig)
        Stopped sig
          | sig == (sigTRAP .|. 0x80) -> if
            | inSyscall -> pure (state{ inSyscall = False }, Right $ SyscallStop SyscallExit)
            | otherwise -> pure (state{ inSyscall = True }, Right $ SyscallStop SyscallEnter)
          | otherwise -> waitForSyscall pid state

      return (newState, exitOrStop)


printSignal :: Signal -> IO ()
printSignal s =
  case find (\(a, _, _) -> s == a) ls of
    Nothing -> putStrLn $ "Unknown signal: " ++ show s
    Just (_, n1, n2) -> do
      print (n1, n2)
  where
  ls :: [(Signal, String, String)]
  ls =
    [ (Signals.nullSignal, "nullSignal", "NULL")
    , (Signals.internalAbort, "internalAbort", "ABRT")
    , (Signals.realTimeAlarm, "realTimeAlarm", "ALRM")
    , (Signals.busError, "busError", "BUS")
    , (Signals.processStatusChanged, "processStatusChanged", "CHLD")
    , (Signals.continueProcess, "continueProcess", "CONT")
    , (Signals.floatingPointException, "floatingPointException", "FPE")
    , (Signals.lostConnection, "lostConnection", "HUP")
    , (Signals.illegalInstruction, "illegalInstruction", "ILL")
    , (Signals.keyboardSignal, "keyboardSignal", "INT")
    , (Signals.killProcess, "killProcess", "KILL")
    , (Signals.openEndedPipe, "openEndedPipe", "PIPE")
    , (Signals.keyboardTermination, "keyboardTermination", "QUIT")
    , (Signals.segmentationViolation, "segmentationViolation", "SEGV")
    , (Signals.softwareStop, "softwareStop", "STOP")
    , (Signals.softwareTermination, "softwareTermination", "TERM")
    , (Signals.keyboardStop, "keyboardStop", "TSTP")
    , (Signals.backgroundRead, "backgroundRead", "TTIN")
    , (Signals.backgroundWrite, "backgroundWrite", "TTOU")
    , (Signals.userDefinedSignal1, "userDefinedSignal1", "USR1")
    , (Signals.userDefinedSignal2, "userDefinedSignal2", "USR2")
    , (Signals.pollableEvent, "pollableEvent", "POLL")
    , (Signals.profilingTimerExpired, "profilingTimerExpired", "PROF")
    , (Signals.badSystemCall, "badSystemCall", "SYS")
    , (Signals.breakpointTrap, "breakpointTrap", "TRAP")
    , (Signals.urgentDataAvailable, "urgentDataAvailable", "URG")
    , (Signals.virtualTimerExpired, "virtualTimerExpired", "VTALRM")
    , (Signals.cpuTimeLimitExceeded, "cpuTimeLimitExceeded", "XCPU")
    , (Signals.fileSizeLimitExceeded, "fileSizeLimitExceeded", "XFSZ")
    ]


data Syscall
  = Read
  | Write
  | Execve
  | Exit
  | UnknownSyscall !Word64
  deriving (Show, Eq)


-- TODO Get this from kernel headers
__X32_SYSCALL_BITMASK :: Word64
__X32_SYSCALL_BITMASK = 0x40000000


-- A good resource for syscall numbers across all architectures is
-- https://fedora.juszkiewicz.com.pl/syscalls.html

syscallNumberToName_i386 :: Word32 -> Syscall
syscallNumberToName_i386 = \case
  1 -> Exit
  3 -> Read
  4 -> Write
  11 -> Execve
  i -> UnknownSyscall (fromIntegral i)


syscallNumberToName_x64_64 :: Word64 -> Syscall
syscallNumberToName_x64_64 = \case
  0 -> Read
  1 -> Write
  59 -> Execve
  60 -> Exit
  i -> UnknownSyscall i


-- | Returns the syscall that we just entered after `waitForSyscall`.
--
-- PRE:
-- This must be called /only/ after `waitForSyscall`; otherwise it may throw
-- an `error` when trying to decode opcodes.
getEnteredSyscall :: CPid -> IO (Syscall)
getEnteredSyscall cpid = do
  regs <- ptrace_getregs cpid
  case regs of
    X86 X86Regs{ orig_eax } -> do
      pure $ syscallNumberToName_i386 orig_eax
    X86_64 X86_64Regs{ orig_rax, rip } -> do
      -- Check whether it's an x86_64 or a legacy i386 syscall,
      -- and look up syscall number accordingly.

      -- Both the `syscall` instruction and the `int 0x80` instruction
      -- are 2 Bytes:
      --   syscall opcode: 0x0F 0x05
      --   int 0x80 opcode: 0xCD 0x80
      -- See
      --   https://www.felixcloutier.com/x86/syscall
      --   https://www.felixcloutier.com/x86/intn:into:int3:int1
      let syscallLocation = wordPtrToPtr (fromIntegral (rip - 2)) -- Word is Word64 on this arch
      -- Note: `peekBytes` has a little-endian-assumption comment in it;
      -- this may not work on big-endian (I haven't checked it)
      opcode <- peekBytes (TracedProcess cpid) syscallLocation 2

      let is_i386_mode = case opcode of
            "\x0F\x05" -> False
            "\xCD\x80" -> True
            _ -> error $ "getEnteredSyscall: BUG: Unexpected syscall opcode: " ++ show opcode

      -- We don't implement x32 support any more, because it may
      -- be removed from the Kernel soon:
      -- https://lkml.org/lkml/2018/12/10/1151

      pure $ if is_i386_mode
        then syscallNumberToName_i386 (fromIntegral orig_rax)
        else syscallNumberToName_x64_64 orig_rax

-- The opcode detection method idea above was motivated by:
--
-- * Michael Bishop (`clever` on freenode)
-- * strace (where it was subsequently removed)
--   * https://superuser.com/questions/834122/how-to-distinguish-syscalls-form-int-80h-when-using-ptrace/1403397#1403397
--   * removal: https://github.com/strace/strace/commit/1f84eefc409291354d0dc7db0866eaf27967da42#diff-3abc305048b4c1c134d1cd2e0eb7799eL113
-- * Linus Torvalds in https://lore.kernel.org/lkml/CA+55aFzcSVmdDj9Lh_gdbz1OzHyEm6ZrGPBDAJnywm2LF_eVyg@mail.gmail.com/
