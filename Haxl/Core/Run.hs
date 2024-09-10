{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- | Defines 'runHaxl'.  Most users should import "Haxl.Core" instead.
--
module Haxl.Core.Run
  ( runHaxl
  , runHaxlWithWrites
  ) where

import Control.Concurrent.STM
import Control.Exception as Exception
import Control.Monad
import Data.IORef
import Data.Maybe
import Text.Printf
import Unsafe.Coerce

import Haxl.Core.DataCache
import Haxl.Core.Exception
import Haxl.Core.Flags
import Haxl.Core.Monad
import Haxl.Core.Fetch
import Haxl.Core.Profile
import Haxl.Core.RequestStore as RequestStore
import Haxl.Core.Stats
import Haxl.Core.Util

import qualified Data.HashTable.IO as H

-- -----------------------------------------------------------------------------
-- runHaxl

-- | Runs a 'Haxl' computation in the given 'Env'.
--
-- Note: to make multiple concurrent calls to 'runHaxl', each one must
-- have a separate 'Env'. A single 'Env' must /not/ be shared between
-- multiple concurrent calls to 'runHaxl', otherwise deadlocks or worse
-- will likely ensue.
--
-- However, multiple 'Env's may share a single 'StateStore', and thereby
-- use the same set of datasources.
runHaxl:: forall u w a. Monoid w => Env u w -> GenHaxl u w a -> IO a
runHaxl env haxl = fst <$> runHaxlWithWrites env haxl

runHaxlWithWrites :: forall u w a. Monoid w => Env u w -> GenHaxl u w a -> IO (a, w)
runHaxlWithWrites env@Env{..} haxl = do
  result@IVar{ivarRef = resultRef} <- newIVar -- where to put the final result
  ifTraceLog <- do
    if trace flags < 3
    then return $ \_ -> return ()
    else do
      start <- getTimestamp
      return $ \s -> do
        now <- getTimestamp
        let t = fromIntegral (now - start) / 1000.0 :: Double
        printf "%.1fms: %s" t (s :: String)
  let
    -- Run a job, and put its result in the given IVar
    schedule :: Env u w -> JobList u w -> GenHaxl u w b -> IVar u w b -> IO ()
    schedule env@Env{..} rq (GenHaxl run) ivar@IVar{ivarRef = !ref} = do
      ifTraceLog $ printf "schedule: %d\n" (1 + lengthJobList rq)
      let {-# INLINE result #-}
          result r = do
            e <- readIORef ref
            case e of
              IVarFull _ ->
                -- An IVar is typically only meant to be written to once
                -- so it would make sense to throw an error here. But there
                -- are legitimate use-cases for writing several times.
                -- (See Haxl.Core.Parallel)
                reschedule env rq
              IVarEmpty haxls -> do
                writeIORef ref (IVarFull r)
                -- Have we got the final result now?
                if ref == unsafeCoerce resultRef
                        -- comparing IORefs of different types is safe, it's
                        -- pointer-equality on the MutVar#.
                   then
                     -- We have a result, but don't discard unfinished
                     -- computations in the run queue. See
                     -- Note [runHaxl and unfinished requests].
                     -- Nothing can depend on the final IVar, so haxls must
                     -- be empty.
                     case rq of
                       JobNil -> return ()
                       _ -> modifyIORef' runQueueRef (appendJobList rq)
                   else reschedule env (appendJobList haxls rq)
      r <-
        if testReportFlag ReportProfiling $ report flags  -- withLabel unfolded
          then Exception.try $ profileCont run env
          else Exception.try $ run env
      case r of
        Left e -> do
          rethrowAsyncExceptions e
          result (ThrowIO e)
        Right (Done a) -> do
          wt <- readIORef writeLogsRef
          result $ Ok a (Just wt)
        Right (Throw ex) -> do
          wt <- readIORef writeLogsRef
          result $ ThrowHaxl ex (Just wt)
        Right (Blocked i fn) -> do
          addJob env (toHaxl fn) ivar i
          reschedule env rq

    -- Here we have a choice:
    --   - If the requestStore is non-empty, we could submit those
    --     requests right away without waiting for more.  This might
    --     be good for latency, especially if the data source doesn't
    --     support batching, or if batching is pessimal.
    --   - To optimise the batch sizes, we want to execute as much as
    --     we can and only submit requests when we have no more
    --     computation to do.
    --   - compromise: wait at least Nms for an outstanding result
    --     before giving up and submitting new requests.
    --
    -- For now we use the batching strategy in the scheduler, but
    -- individual data sources can request that their requests are
    -- sent eagerly by using schedulerHint.
    --
    reschedule :: Env u w -> JobList u w -> IO ()
    reschedule env@Env{..} haxls = do
      case haxls of
        JobNil -> do
          rq <- readIORef runQueueRef
          case rq of
            JobNil -> emptyRunQueue env
            JobCons env' a b c -> do
              writeIORef runQueueRef JobNil
              schedule env' c a b
        JobCons env' a b c ->
          schedule env' c a b

    emptyRunQueue :: Env u w -> IO ()
    emptyRunQueue env = do
      ifTraceLog $ printf "emptyRunQueue\n"
      haxls <- checkCompletions env
      case haxls of
        JobNil -> checkRequestStore env
        _ -> reschedule env haxls

    checkRequestStore :: Env u w -> IO ()
    checkRequestStore env@Env{..} = do
      ifTraceLog $ printf "checkRequestStore\n"
      reqStore <- readIORef reqStoreRef
      if RequestStore.isEmpty reqStore
        then waitCompletions env
        else do
          ifTraceLog $ printf "performFetches %d\n" (RequestStore.getSize reqStore)
          writeIORef reqStoreRef noRequests
          performRequestStore env reqStore
          -- empty the cache if we're not caching.  Is this the best
          -- place to do it?  We do get to de-duplicate requests that
          -- happen simultaneously.
          when (caching flags == 0) $ do
            let DataCache dc = dataCache
            H.foldM (\_ (k, _) -> H.delete dc k) () dc
          emptyRunQueue env

    checkCompletions :: Env u w -> IO (JobList u w)
    checkCompletions Env{..} = do
      ifTraceLog $ printf "checkCompletions\n"
      comps <- atomicallyOnBlocking (LogicBug ReadingCompletionsFailedRun) $ do
        c <- readTVar completions
        writeTVar completions []
        return c
      case comps of
        [] -> return JobNil
        _ -> do
          ifTraceLog $ printf "%d complete\n" (length comps)
          let
              getComplete (CompleteReq a IVar{ivarRef = !cr} allocs) = do
                when (allocs < 0) $ do
                  cur <- getAllocationCounter
                  setAllocationCounter (cur + allocs)
                r <- readIORef cr
                case r of
                  IVarFull _ -> do
                    ifTraceLog $ printf "existing result\n"
                    return JobNil
                    -- this happens if a data source reports a result,
                    -- and then throws an exception.  We call putResult
                    -- a second time for the exception, which comes
                    -- ahead of the original request (because it is
                    -- pushed on the front of the completions list) and
                    -- therefore overrides it.
                  IVarEmpty cv -> do
                    writeIORef cr (IVarFull a)
                    return cv
          jobs <- mapM getComplete comps
          return (foldr appendJobList JobNil jobs)

    waitCompletions :: Env u w -> IO ()
    waitCompletions env@Env{..} = do
      ifTraceLog $ printf "waitCompletions\n"
      let
        wrapped = atomicallyOnBlocking (LogicBug ReadingCompletionsFailedRun)
        doWait = wrapped $ do
          c <- readTVar completions
          when (null c) retry
        doWaitProfiled = do
          queueEmpty <- null <$> wrapped (readTVar completions)
          when queueEmpty $ do
            -- Double check the queue as we want to make sure that
            -- submittedReqsRef is copied before waiting on the queue but as a
            -- fast path do not want to copy it if the queue is empty.
            -- There is still a race oppoortunity as submittedReqsRef is
            -- decremented in whatever thread the completion happens, and so it
            -- is possible for waitingOn to be empty while queueEmpty2 is True.
            waitingOn <- readIORef submittedReqsRef
            queueEmpty2 <- null <$> wrapped (readTVar completions)
            when queueEmpty2 $ do
              start <- getTimestamp
              doWait
              end <- getTimestamp
              let fw = FetchWait
                        { fetchWaitReqs = getSummaryMapFromRCMap waitingOn
                        , fetchWaitStart = start
                        , fetchWaitDuration = (end-start)
                        }
              modifyIORef' statsRef $ \(Stats s) -> Stats (fw:s)
      if testReportFlag ReportFetchStats $ report flags
        then doWaitProfiled
        else doWait
      emptyRunQueue env

  --
  schedule env JobNil haxl result
  r <- readIORef resultRef
  writeIORef writeLogsRef mempty
  wtNoMemo <- atomicModifyIORef' writeLogsRefNoMemo
    (\old_wrts -> (mempty, old_wrts))
  case r of
    IVarEmpty _ -> throwIO (CriticalError "runHaxl: missing result")
    IVarFull (Ok a wt) -> do
      return (a, fromMaybe mempty wt <> wtNoMemo)
    IVarFull (ThrowHaxl e _wt)  -> throwIO e
      -- The written logs are discarded when there's a Haxl exception. We
      -- can change this behavior if we need to get access to partial logs.
    IVarFull (ThrowIO e)  -> throwIO e


{- Note [runHaxl and unfinished requests]

runHaxl returns immediately when the supplied computation has returned
a result.  This doesn't necessarily mean that the whole computation
graph has completed, however.  In particular, when using pAnd and pOr,
we might have created some data fetches that have not completed, but
weren't required, because the other branch of the pAnd/pOr subsumed
the result.

When runHaxl returns, it might be that:
- reqStoreRef contains some unsubmitted requests
- runQueueRef contains some jobs
- there are in-flight BackgroundFetch requests, that will return their
  results to the completions queue in due course.
- there are various unfilled IVars in the cache and/or memo tables

This should be all safe, we can even restart runHaxl with the same Env
after it has stopped and the in-progress computations will
continue. But don't discard the contents of
reqStoreRef/runQueueRef/completions, because then we'll deadlock if we
discover one of the unfilled IVars in the cache or memo table.
-}

{- TODO: later
data SchedPolicy
  = SubmitImmediately
  | WaitAtLeast Int{-ms-}
  | WaitForAllPendingRequests
-}

-- | An exception thrown when reading from datasources fails
data ReadingCompletionsFailedRun = ReadingCompletionsFailedRun
  deriving Show

instance Exception ReadingCompletionsFailedRun
