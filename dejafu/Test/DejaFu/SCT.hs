{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Test.DejaFu.SCT
-- Copyright   : (c) 2015--2018 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : BangPatterns, GADTs, GeneralizedNewtypeDeriving, LambdaCase, RankNTypes
--
-- Systematic testing for concurrent computations.
module Test.DejaFu.SCT
  ( -- * Running Concurrent Programs
    Way
  , systematically
  , randomly
  , uniformly
  , swarmy
  , runSCT
  , resultsSet

  -- ** Discarding variants
  , Discard(..)
  , runSCTDiscard
  , resultsSetDiscard

  -- ** Configuration
  , Settings
  , fromWayAndMemType
  , runSCTWithSettings
  , resultsSetWithSettings

  -- *** Lenses
  , lway
  , lmemtype
  , ldiscard
  , ldebugShow
  , ldebugPrint

  -- *** Lens helpers
  , get
  , set

  -- ** Strict variants
  , runSCT'
  , resultsSet'
  , runSCTDiscard'
  , resultsSetDiscard'
  , runSCTWithSettings'
  , resultsSetWithSettings'

  -- * Bounded Partial-order Reduction

  -- | We can characterise the state of a concurrent computation by
  -- considering the ordering of dependent events. This is a partial
  -- order: independent events can be performed in any order without
  -- affecting the result, and so are /not/ ordered.
  --
  -- Partial-order reduction is a technique for computing these
  -- partial orders, and only testing one total order for each partial
  -- order. This cuts down the amount of work to be done
  -- significantly. /Bounded/ partial-order reduction is a further
  -- optimisation, which only considers schedules within some bound.
  --
  -- This module provides a combination pre-emption, fair, and length
  -- bounding runner:
  --
  -- * Pre-emption + fair bounding is useful for programs which use
  --   loop/yield control flows but are otherwise terminating.
  --
  -- * Pre-emption, fair + length bounding is useful for
  --   non-terminating programs, and used by the testing functionality
  --   in @Test.DejaFu@.
  --
  -- See /Bounded partial-order reduction/, K. Coons, M. Musuvathi,
  -- K. McKinley for more details.

  , Bounds(..)
  , PreemptionBound(..)
  , FairBound(..)
  , LengthBound(..)
  , noBounds
  , sctBound
  , sctBoundDiscard

  -- * Random Scheduling

  -- | By greatly sacrificing completeness, testing of a large
  -- concurrent system can be greatly sped-up. Counter-intuitively,
  -- random scheduling has better bug-finding behaviour than just
  -- executing a program \"for real\" many times. This is perhaps
  -- because a random scheduler is more chaotic than the real
  -- scheduler.

  , sctUniformRandom
  , sctWeightedRandom
  , sctUniformRandomDiscard
  , sctWeightedRandomDiscard
  ) where

import           Control.Applicative               (Const(..), (<|>))
import           Control.DeepSeq                   (NFData(..), force)
import           Control.Monad.Conc.Class          (MonadConc)
import           Control.Monad.Ref                 (MonadRef)
import           Data.Functor.Identity             (Identity(..))
import           Data.List                         (foldl')
import qualified Data.Map.Strict                   as M
import           Data.Maybe                        (fromMaybe)
import           Data.Set                          (Set)
import qualified Data.Set                          as S
import           System.Random                     (RandomGen, randomR)

import           Test.DejaFu.Conc
import           Test.DejaFu.Internal
import           Test.DejaFu.SCT.Internal.DPOR
import           Test.DejaFu.SCT.Internal.Weighted
import           Test.DejaFu.Types
import           Test.DejaFu.Utils

-------------------------------------------------------------------------------
-- Running Concurrent Programs

-- | How to explore the possible executions of a concurrent program.
--
-- @since 0.7.0.0
data Way where
  Systematic :: Bounds -> Way
  Weighted   :: RandomGen g => g -> Int -> Int -> Way
  Uniform    :: RandomGen g => g -> Int -> Way

instance Show Way where
  show (Systematic bs)  = "Systematic (" ++ show bs ++ ")"
  show (Weighted _ n t) = "Weighted <gen> " ++ show (n, t)
  show (Uniform  _ n)   = "Uniform <gen> " ++ show n

-- | Systematically execute a program, trying all distinct executions
-- within the bounds.
--
-- This corresponds to 'sctBound'.
--
-- @since 0.7.0.0
systematically
  :: Bounds
  -- ^ The bounds to constrain the exploration.
  -> Way
systematically = Systematic

-- | Randomly execute a program, exploring a fixed number of
-- executions.
--
-- Threads are scheduled by a weighted random selection, where weights
-- are assigned randomly on thread creation.
--
-- This corresponds to 'sctWeightedRandom' with weight re-use
-- disabled, and is not guaranteed to find all distinct results
-- (unlike 'systematically' / 'sctBound').
--
-- @since 0.7.0.0
randomly :: RandomGen g
  => g
  -- ^ The random generator to drive the scheduling.
  -> Int
  -- ^ The number of executions to try.
  -> Way
randomly g lim = swarmy g lim 1

-- | Randomly execute a program, exploring a fixed number of
-- executions.
--
-- Threads are scheduled by a uniform random selection.
--
-- This corresponds to 'sctUniformRandom', and is not guaranteed to
-- find all distinct results (unlike 'systematically' / 'sctBound').
--
-- @since 0.7.0.0
uniformly :: RandomGen g
  => g
  -- ^ The random generator to drive the scheduling.
  -> Int
  -- ^ The number of executions to try.
  -> Way
uniformly = Uniform

-- | Randomly execute a program, exploring a fixed number of
-- executions.
--
-- Threads are scheduled by a weighted random selection, where weights
-- are assigned randomly on thread creation.
--
-- This corresponds to 'sctWeightedRandom', and is not guaranteed to
-- find all distinct results (unlike 'systematically' / 'sctBound').
--
-- @since 0.7.0.0
swarmy :: RandomGen g
  => g
  -- ^ The random generator to drive the scheduling.
  -> Int
  -- ^ The number of executions to try.
  -> Int
  -- ^ The number of executions to use the thread weights for.
  -> Way
swarmy = Weighted

-- | Explore possible executions of a concurrent program according to
-- the given 'Way'.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since 1.0.0.0
runSCT :: (MonadConc n, MonadRef r n)
  => Way
  -- ^ How to run the concurrent program.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
runSCT way = runSCTWithSettings . fromWayAndMemType way

-- | Return the set of results of a concurrent program.
--
-- @since 1.0.0.0
resultsSet :: (MonadConc n, MonadRef r n, Ord a)
  => Way
  -- ^ How to run the concurrent program.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n (Set (Either Failure a))
resultsSet way = resultsSetWithSettings . fromWayAndMemType way

-- | A variant of 'runSCT' which can selectively discard results.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since 1.0.0.0
runSCTDiscard :: (MonadConc n, MonadRef r n)
  => (Either Failure a -> Maybe Discard)
  -- ^ Selectively discard results.
  -> Way
  -- ^ How to run the concurrent program.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
runSCTDiscard discard way = runSCTWithSettings . set ldiscard discard . fromWayAndMemType way

-- | A variant of 'resultsSet' which can selectively discard results.
--
-- @since 1.0.0.0
resultsSetDiscard :: (MonadConc n, MonadRef r n, Ord a)
  => (Either Failure a -> Maybe Discard)
  -- ^ Selectively discard results.  Traces are always discarded.
  -> Way
  -- ^ How to run the concurrent program.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n (Set (Either Failure a))
resultsSetDiscard discard way memtype conc =
  let discard' efa = discard efa <|> Just DiscardTrace
  in S.fromList . map fst <$> runSCTDiscard discard' way memtype conc

-- | A strict variant of 'runSCT'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since 1.0.0.0
runSCT' :: (MonadConc n, MonadRef r n, NFData a)
  => Way -> MemType -> ConcT r n a -> n [(Either Failure a, Trace)]
runSCT' way = runSCTWithSettings' . fromWayAndMemType way

-- | A strict variant of 'resultsSet'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
--
-- @since 1.0.0.0
resultsSet' :: (MonadConc n, MonadRef r n, Ord a, NFData a)
  => Way -> MemType -> ConcT r n a -> n (Set (Either Failure a))
resultsSet' way = resultsSetWithSettings' . fromWayAndMemType way

-- | A strict variant of 'runSCTDiscard'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since 1.0.0.0
runSCTDiscard' :: (MonadConc n, MonadRef r n, NFData a)
  => (Either Failure a -> Maybe Discard) -> Way -> MemType -> ConcT r n a -> n [(Either Failure a, Trace)]
runSCTDiscard' discard way memtype conc = do
  res <- runSCTDiscard discard way memtype conc
  rnf res `seq` pure res

-- | A strict variant of 'resultsSetDiscard'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
--
-- @since 1.0.0.0
resultsSetDiscard' :: (MonadConc n, MonadRef r n, Ord a, NFData a)
  => (Either Failure a -> Maybe Discard) -> Way -> MemType -> ConcT r n a -> n (Set (Either Failure a))
resultsSetDiscard' discard way memtype conc = do
  res <- resultsSetDiscard discard way memtype conc
  rnf res `seq` pure res

-------------------------------------------------------------------------------
-- Configuration

-- | SCT configuration record.
--
-- See 'fromWayAndMemType', 'lway', 'lmemtype', 'ldiscarder',
-- 'ldebugShow', and 'ldebugPrint'.
--
-- @since unreleased
data Settings n a = Settings
  { _way :: Way
  , _memtype :: MemType
  , _discard :: Either Failure a -> Maybe Discard
  , _debugShow :: a -> String
  , _debugPrint :: String -> n ()
  }

-- lens type synonyms, unexported
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t
type Lens' s a = Lens s s a a

-- | A lens into the 'Way'.
--
-- @since unreleased
lway :: Lens' (Settings n a) Way
lway afb s = (\b -> s {_way = b}) <$> afb (_way s)

-- | A lens into the 'MemType'.
--
-- @since unreleased
lmemtype :: Lens' (Settings n a) MemType
lmemtype afb s = (\b -> s {_memtype = b}) <$> afb (_memtype s)

-- | A lens into the discard function.
--
-- @since unreleased
ldiscard :: Lens' (Settings n a) (Either Failure a -> Maybe Discard)
ldiscard afb s = (\b -> s {_discard = b}) <$> afb (_discard s)

-- | A lens into the debug 'show' function.
--
-- @since unreleased
ldebugShow :: Lens' (Settings n a) (a -> String)
ldebugShow afb s = (\b -> s {_debugShow = b}) <$> afb (_debugShow s)

-- | A lens into the debug 'print' function.
--
-- @since unreleased
ldebugPrint :: Lens' (Settings n a) (String -> n ())
ldebugPrint afb s = (\b -> s {_debugPrint = b}) <$> afb (_debugPrint s)

-- | Construct a 'Settings' record from a 'Way' and a 'MemType'.
--
-- All other settings take on their default values.
--
-- @since unreleased
fromWayAndMemType :: Applicative n => Way -> MemType -> Settings n a
fromWayAndMemType way memtype = Settings
  { _way = way
  , _memtype = memtype
  , _discard = const Nothing
  , _debugShow = const "_"
  , _debugPrint = const (pure ())
  }

-- | Get a value from a lens.
--
-- @since unreleased
get :: Lens' s a -> s -> a
get lens = getConst . lens Const

-- | Set a value in a lens.
--
-- @since unreleased
set :: Lens' s a -> a -> s -> s
set lens a = runIdentity . lens (\_ -> Identity a)

-- | A variant of 'runSCT' which takes a 'Settings' record.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since unreleased
runSCTWithSettings :: (MonadConc n, MonadRef r n)
  => Settings n a
  -- ^ The SCT settings.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
runSCTWithSettings settings conc = case _way settings of
  Systematic cb0 ->
    let initial = initialState

        check = findSchedulePrefix

        step dp (prefix, conservative, sleep) run = do
          (res, s, trace) <- run
            (dporSched (cBound cb0))
            (initialDPORSchedState sleep prefix)

          let bpoints = findBacktrackSteps (cBacktrack cb0) (schedBoundKill s) (schedBPoints s) trace
          let newDPOR = incorporateTrace conservative trace dp

          pure $ if schedIgnore s
                 then (force newDPOR, Nothing)
                 else (force (incorporateBacktrackSteps bpoints newDPOR), Just (res, trace))
    in sct settings initial check step conc

  Uniform g0 lim0 ->
    let initial _ = (g0, max 0 lim0)

        check (_, 0) = Nothing
        check s = Just s

        step _ (g, n) run = do
          (res, s, trace) <- run
            (randSched $ \g' -> (1, g'))
            (initialRandSchedState Nothing g)
          pure ((schedGen s, n-1), Just (res, trace))
    in sct settings initial check step conc

  Weighted g0 lim0 use0 ->
    let initial _ = (g0, max 0 lim0, max 1 use0, M.empty)

        check (_, 0, _, _) = Nothing
        check s = Just s

        step s (g, n, 0, _) run = step s (g, n, max 1 use0, M.empty) run
        step _ (g, n, use, ws) run = do
          (res, s, trace) <- run
            (randSched $ randomR (1, 50))
            (initialRandSchedState (Just ws) g)
          pure ((schedGen s, n-1, use-1, schedWeights s), Just (res, trace))
    in sct settings initial check step conc

-- | A variant of 'resultsSet' which takes a 'Settings' record.
--
-- @since unreleased
resultsSetWithSettings :: (MonadConc n, MonadRef r n, Ord a)
  => Settings n a
  -- ^ The SCT settings.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n (Set (Either Failure a))
resultsSetWithSettings settings conc =
  let settings' = settings { _discard = \efa -> _discard settings efa <|> Just DiscardTrace }
  in S.fromList . map fst <$> runSCTWithSettings settings' conc

-- | A strict variant of 'runSCTWithSettings'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since unreleased
runSCTWithSettings' :: (MonadConc n, MonadRef r n, NFData a)
  => Settings n a
  -> ConcT r n a
  -> n [(Either Failure a, Trace)]
runSCTWithSettings' settings conc = do
  res <- runSCTWithSettings settings conc
  rnf res `seq` pure res

-- | A strict variant of 'resultsSetWithSettings'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
--
-- @since unreleased
resultsSetWithSettings' :: (MonadConc n, MonadRef r n, Ord a, NFData a)
  => Settings n a
  -> ConcT r n a
  -> n (Set (Either Failure a))
resultsSetWithSettings' settings conc = do
  res <- resultsSetWithSettings settings conc
  rnf res `seq` pure res

-------------------------------------------------------------------------------
-- Combined Bounds

-- | @since 0.2.0.0
data Bounds = Bounds
  { boundPreemp :: Maybe PreemptionBound
  , boundFair   :: Maybe FairBound
  , boundLength :: Maybe LengthBound
  } deriving (Eq, Ord, Read, Show)

-- | @since 0.5.1.0
instance NFData Bounds where
  rnf bs = rnf ( boundPreemp bs
               , boundFair   bs
               , boundLength bs
               )

-- | No bounds enabled. This forces the scheduler to just use
-- partial-order reduction and sleep sets to prune the search
-- space. This will /ONLY/ work if your computation always terminates!
--
-- @since 0.3.0.0
noBounds :: Bounds
noBounds = Bounds
  { boundPreemp = Nothing
  , boundFair   = Nothing
  , boundLength = Nothing
  }

-- | Combination bound function
cBound :: Bounds -> IncrementalBoundFunc ((Int, Maybe ThreadId), M.Map ThreadId Int, Int)
cBound (Bounds pb fb lb) (Just (k1, k2, k3)) prior lh =
  let k1' = maybe (\k _ _ -> k) pBound pb (Just k1) prior lh
      k2' = maybe (\k _ _ -> k) fBound fb (Just k2) prior lh
      k3' = maybe (\k _ _ -> k) lBound lb (Just k3) prior lh
  in (,,) <$> k1' <*> k2' <*> k3'
cBound _ Nothing _ _ = Just ((0, Nothing), M.empty, 1)

-- | Combination backtracking function. Add all backtracking points
-- corresponding to enabled bound functions.
--
-- If no bounds are enabled, just backtrack to the given point.
cBacktrack :: Bounds -> BacktrackFunc
cBacktrack (Bounds (Just _) _ _) = pBacktrack
cBacktrack (Bounds _ (Just _) _) = fBacktrack
cBacktrack (Bounds _ _ (Just _)) = lBacktrack
cBacktrack _ = backtrackAt (\_ _ -> False)

-------------------------------------------------------------------------------
-- Pre-emption bounding

-- | BPOR using pre-emption bounding. This adds conservative
-- backtracking points at the prior context switch whenever a
-- non-conervative backtracking point is added, as alternative
-- decisions can influence the reachability of different states.
--
-- See the BPOR paper for more details.
--
-- @since 0.2.0.0
newtype PreemptionBound = PreemptionBound Int
  deriving (Enum, Eq, Ord, Num, Real, Integral, Read, Show)

-- | @since 0.5.1.0
instance NFData PreemptionBound where
  -- not derived, so it can have a separate @since annotation
  rnf (PreemptionBound i) = rnf i

-- | Pre-emption bound function. This does not count pre-emptive
-- context switches to a commit thread.
pBound :: PreemptionBound -> IncrementalBoundFunc (Int, Maybe ThreadId)
pBound (PreemptionBound pb) k prior lhead =
  let k'@(pcount, _) = preEmpCountInc (fromMaybe (0, Nothing) k) prior lhead
  in if pcount <= pb then Just k' else Nothing

-- | Add a backtrack point, and also conservatively add one prior to
-- the most recent transition before that point. This may result in
-- the same state being reached multiple times, but is needed because
-- of the artificial dependency imposed by the bound.
pBacktrack :: BacktrackFunc
pBacktrack bs = backtrackAt (\_ _ -> False) bs . concatMap addConservative where
  addConservative o@(i, _, tid) = o : case conservative i of
    Just j  -> [(j, True, tid)]
    Nothing -> []

  -- index of conservative point
  conservative i = go (reverse (take (i-1) bs)) (i-1) where
    go _ (-1) = Nothing
    go (b1:rest@(b2:_)) j
      | bcktThreadid b1 /= bcktThreadid b2
        && not (isCommitRef $ bcktAction b1)
        && not (isCommitRef $ bcktAction b2) = Just j
      | otherwise = go rest (j-1)
    go _ _ = Nothing

-------------------------------------------------------------------------------
-- Fair bounding

-- | BPOR using fair bounding. This bounds the maximum difference
-- between the number of yield operations different threads have
-- performed.
--
-- See the BPOR paper for more details.
--
-- @since 0.2.0.0
newtype FairBound = FairBound Int
  deriving (Enum, Eq, Ord, Num, Real, Integral, Read, Show)

-- | @since 0.5.1.0
instance NFData FairBound where
  -- not derived, so it can have a separate @since annotation
  rnf (FairBound i) = rnf i

-- | Fair bound function
fBound :: FairBound -> IncrementalBoundFunc (M.Map ThreadId Int)
fBound (FairBound fb) k prior lhead =
  let k' = yieldCountInc (fromMaybe M.empty k) prior lhead
  in if not (willYield (snd lhead)) || maxDiff (M.elems k') <= fb
     then Just k'
     else Nothing

-- | Add a backtrack point. If the thread doesn't exist or is blocked,
-- or performs a release operation, add all unblocked threads.
fBacktrack :: BacktrackFunc
fBacktrack = backtrackAt check where
  -- True if a release operation is performed.
  check t b = Just True == (willRelease <$> M.lookup t (bcktRunnable b))

-------------------------------------------------------------------------------
-- Length bounding

-- | BPOR using length bounding. This bounds the maximum length (in
-- terms of primitive actions) of an execution.
--
-- @since 0.2.0.0
newtype LengthBound = LengthBound Int
  deriving (Enum, Eq, Ord, Num, Real, Integral, Read, Show)

-- | @since 0.5.1.0
instance NFData LengthBound where
  -- not derived, so it can have a separate @since annotation
  rnf (LengthBound i) = rnf i

-- | Length bound function
lBound :: LengthBound -> IncrementalBoundFunc Int
lBound (LengthBound lb) len _ _ =
  let len' = maybe 1 (+1) len
  in if len' < lb then Just len' else Nothing

-- | Add a backtrack point. If the thread doesn't exist or is blocked,
-- add all unblocked threads.
lBacktrack :: BacktrackFunc
lBacktrack = backtrackAt (\_ _ -> False)

-------------------------------------------------------------------------------
-- Systematic concurrency testing

-- | SCT via BPOR.
--
-- Schedules are generated by running the computation with a
-- deterministic scheduler with some initial list of decisions. At
-- each step of execution, possible-conflicting actions are looked
-- for, if any are found, \"backtracking points\" are added, to cause
-- the events to happen in a different order in a future execution.
--
-- Note that unlike with non-bounded partial-order reduction, this may
-- do some redundant work as the introduction of a bound can make
-- previously non-interfering events interfere with each other.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since 1.0.0.0
sctBound :: (MonadConc n, MonadRef r n)
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> Bounds
  -- ^ The combined bounds.
  -> ConcT r n a
  -- ^ The computation to run many times
  -> n [(Either Failure a, Trace)]
sctBound = sctBoundDiscard (const Nothing)

-- | A variant of 'sctBound' which can selectively discard results.
--
-- The exact executions tried, and the order in which results are
-- found, is unspecified and may change between releases.
--
-- @since 1.0.0.0
sctBoundDiscard :: (MonadConc n, MonadRef r n)
  => (Either Failure a -> Maybe Discard)
  -- ^ Selectively discard results.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> Bounds
  -- ^ The combined bounds.
  -> ConcT r n a
  -- ^ The computation to run many times
  -> n [(Either Failure a, Trace)]
sctBoundDiscard discard memtype cb = runSCTWithSettings $
  set ldiscard discard (fromWayAndMemType (systematically cb) memtype)

-- | SCT via uniform random scheduling.
--
-- Schedules are generated by assigning to each new thread a random
-- weight. Threads are then scheduled by a weighted random selection.
--
-- This is not guaranteed to find all distinct results.
--
-- @since 1.0.0.0
sctUniformRandom :: (MonadConc n, MonadRef r n, RandomGen g)
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> g
  -- ^ The random number generator.
  -> Int
  -- ^ The number of executions to perform.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
sctUniformRandom = sctUniformRandomDiscard (const Nothing)

-- | A variant of 'sctUniformRandom' which can selectively discard
-- results.
--
-- This is not guaranteed to find all distinct results.
--
-- @since 1.0.0.0
sctUniformRandomDiscard :: (MonadConc n, MonadRef r n, RandomGen g)
  => (Either Failure a -> Maybe Discard)
  -- ^ Selectively discard results.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> g
  -- ^ The random number generator.
  -> Int
  -- ^ The number of executions to perform.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
sctUniformRandomDiscard discard memtype g lim = runSCTWithSettings $
  set ldiscard discard (fromWayAndMemType (uniformly g lim) memtype)

-- | SCT via weighted random scheduling.
--
-- Schedules are generated by assigning to each new thread a random
-- weight. Threads are then scheduled by a weighted random selection.
--
-- This is not guaranteed to find all distinct results.
--
-- @since 1.0.0.0
sctWeightedRandom :: (MonadConc n, MonadRef r n, RandomGen g)
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> g
  -- ^ The random number generator.
  -> Int
  -- ^ The number of executions to perform.
  -> Int
  -- ^ The number of executions to use the same set of weights for.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
sctWeightedRandom = sctWeightedRandomDiscard (const Nothing)

-- | A variant of 'sctWeightedRandom' which can selectively discard
-- results.
--
-- This is not guaranteed to find all distinct results.
--
-- @since 1.0.0.0
sctWeightedRandomDiscard :: (MonadConc n, MonadRef r n, RandomGen g)
  => (Either Failure a -> Maybe Discard)
  -- ^ Selectively discard results.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> g
  -- ^ The random number generator.
  -> Int
  -- ^ The number of executions to perform.
  -> Int
  -- ^ The number of executions to use the same set of weights for.
  -> ConcT r n a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
sctWeightedRandomDiscard discard memtype g lim use = runSCTWithSettings $
  set ldiscard discard (fromWayAndMemType (swarmy g lim use) memtype)

-- | General-purpose SCT function.
sct :: (MonadConc n, MonadRef r n)
  => Settings n a
  -- ^ The SCT settings ('Way' is ignored)
  -> ([ThreadId] -> s)
  -- ^ Initial state
  -> (s -> Maybe t)
  -- ^ State predicate
  -> (s -> t -> (Scheduler g -> g -> n (Either Failure a, g, Trace)) -> n (s, Maybe (Either Failure a, Trace)))
  -- ^ Run the computation and update the state
  -> ConcT r n a
  -> n [(Either Failure a, Trace)]
sct settings s0 sfun srun conc
    | canDCSnapshot conc = runForDCSnapshot conc >>= \case
        Just (Right snap, _) -> go (runSnap snap) (fst (threadsFromDCSnapshot snap))
        Just (Left f, trace) -> pure [(Left f, trace)]
        _ -> do
          _debugPrint settings "Failed to construct snapshot, continuing without."
          go runFull [initialThread]
    | otherwise = go runFull [initialThread]
  where
    go run = go' . s0 where
      go' !s = case sfun s of
        Just t -> srun s t run >>= \case
          (s', Just (res, trace)) -> case _discard settings res of
            Just DiscardResultAndTrace -> go' s'
            Just DiscardTrace -> ((res, []):) <$> go' s'
            Nothing -> ((res, trace):) <$> go' s'
          (s', Nothing) -> go' s'
        Nothing -> pure []

    runFull sched s = runConcurrent sched (_memtype settings) s conc
    runSnap snap sched s = runWithDCSnapshot sched (_memtype settings) s snap

-------------------------------------------------------------------------------
-- Utilities

-- | An incremental version of 'preEmpCount', going one step at a time.
preEmpCountInc
  :: (Int, Maybe ThreadId)
  -- ^ The number of preemptions so far and, if currently executing a
  -- commit thread, what the prior thread was.
  -> Maybe (ThreadId, ThreadAction)
  -- ^ What just happened.
  -> (Decision, a)
  -- ^ What's coming up.
  -> (Int, Maybe ThreadId)
preEmpCountInc (sofar, lastnoncommit) prior (d, _) = case (prior, d) of
    (Just (tid, _),   Start    tnext) -> cswitch tid tnext False
    (Just (tid, act), SwitchTo tnext) -> cswitch tid tnext (not (didYield act))
    (_, Continue) -> (sofar, lastnoncommit)
    (Nothing, _)  -> (sofar, lastnoncommit)
  where
    cswitch tid tnext isPreemptive
      | isCommitThread tnext = (sofar, if isCommitThread tid then lastnoncommit else Just tid)
      | isCommitThread tid   = (if lastnoncommit == Just tnext then sofar else sofar + 1, Nothing)
      | otherwise = (if isPreemptive then sofar + 1 else sofar, Nothing)

    isCommitThread = (< initialThread)

-- | An incremental count of yields, going one step at a time.
yieldCountInc
  :: M.Map ThreadId Int
  -- ^ The number of yields of each thread so far
  -> Maybe (ThreadId, a)
  -- ^ What just happened.
  -> (Decision, Lookahead)
  -- ^ What's coming up.
  -> M.Map ThreadId Int
yieldCountInc sofar prior (d, lnext) = case prior of
    Just (tid, _) -> ycount (tidOf tid d)
    Nothing       -> ycount initialThread
  where
    ycount tnext
      | willYield lnext = M.alter (Just . maybe 1 (+1)) tnext sofar
      | otherwise       = M.alter (Just . fromMaybe 0) tnext sofar

-- | Determine if an action is a commit or not.
isCommitRef :: ThreadAction -> Bool
isCommitRef (CommitCRef _ _) = True
isCommitRef _ = False

-- | Get the maximum difference between two ints in a list.
maxDiff :: [Int] -> Int
maxDiff = go 0 where
  go m (x:xs) =
    let m' = m `max` foldl' (go' x) 0 xs
    in go m' xs
  go m [] = m
  go' x0 m x = m `max` abs (x0 - x)
