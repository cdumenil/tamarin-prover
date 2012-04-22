{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, UndecidableInstances #-}  -- require for MonadError
-- |
-- Copyright   : (c) 2010-2012 Simon Meier
-- License     : GPL v3 (see LICENSE)
-- 
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- A monad transformer for passing a fresh name supply through a computation.
-- The name supply is precise in the sense that every 'String' has its own
-- supply of indices for the next fresh name.
--
-- Modeled after the mtl-2.0 library.
--
module Control.Monad.Trans.PreciseFresh (

  -- * The Fresh monad
    Fresh
  , runFresh
  , evalFresh
  , execFresh

  -- * The FreshT monad transformer
  , FreshT(..)
  , freshT
  , runFreshT
  , evalFreshT
  , execFreshT

  -- * Fresh name generation
  , FreshState
  , nothingUsed
  , freshIdent
  , freshIdents

  ) where

import Control.Basics
import Control.Monad.Identity
import Control.Monad.State.Strict
import Control.Monad.Error
import Control.Monad.Reader

import qualified Data.Map as M

------------------------------------------------------------------------------
-- FreshT monad transformer
------------------------------------------------------------------------------

-- | The state of the name supply: the first unused sequence number of every name.
type FreshState = M.Map String Int

-- | A computation that can generate fresh variables from name hints.
newtype FreshT m a = FreshT { unFreshT :: StateT FreshState m a }
    deriving( Functor, Applicative, Alternative, Monad, MonadPlus, MonadTrans )

-- | Construct a 'FreshT' action from a 'FreshState' modification.
freshT :: (FreshState -> m (a, FreshState)) -> FreshT m a
freshT = FreshT . StateT

-- | The empty fresh state.
nothingUsed :: FreshState
nothingUsed = M.empty

-- | Run a computation with a fresh name supply.
runFreshT :: FreshT m a -> FreshState -> m (a, FreshState)
runFreshT (FreshT m) used = runStateT m used

-- | Evaluate a computation with a fresh name supply.
evalFreshT :: Monad m => FreshT m a -> FreshState -> m a
evalFreshT (FreshT m) used = evalStateT m used

-- | Execute a computation with a fresh name supply.
execFreshT :: Monad m => FreshT m a -> FreshState -> m FreshState
execFreshT (FreshT m) used = execStateT m used

-- | /O(log(n))/. Get a fresh identifiers for the given name.
freshIdent :: Monad m
            => String        -- ^ number of desired identifiers
            -> FreshT m Int  -- ^ The first fresh identifier.
freshIdent name = do
    m <- FreshT get
    let i = M.findWithDefault 0 name m
    FreshT (modify (M.insert name (succ i)))
    return i

-- | /O(n)/. Get 'k' fresh identifiers.
freshIdents :: Monad m
            => Int           -- ^ number of desired identifiers
            -> FreshT m Int  -- ^ The first fresh identifier.
freshIdents k = do
    m <- FreshT get
    let maxIdx = maximum $ 0 : map snd (M.toList m)
        nextIdx = maxIdx + k
    -- insert 'nextIdx' at "" to remember it for the next call
    FreshT (put (M.insert "" nextIdx $ M.map (const nextIdx) m))
    return maxIdx


-- Instances
------------

instance MonadError e m => MonadError e (FreshT m) where
    throwError     = lift . throwError
    catchError m h = FreshT $ catchError (unFreshT m) (unFreshT . h)

instance MonadReader r m => MonadReader r (FreshT m) where
    ask       = lift ask
    local f m = FreshT $ local f $ unFreshT m

instance MonadState s m => MonadState s (FreshT m) where
    get   = lift get
    put s = lift $ put s

------------------------------------------------------------------------------
-- Fresh monad
------------------------------------------------------------------------------

type Fresh = FreshT Identity

-- | Run a computation with a fresh name supply.
runFresh :: Fresh a -> FreshState -> (a, FreshState)
runFresh (FreshT m) used = runState m used

-- | Evaluate a computation with a fresh name supply.
evalFresh :: Fresh a -> FreshState -> a
evalFresh (FreshT m) used = evalState m used

-- | Execute a computation with a fresh name supply.
execFresh :: Fresh a -> FreshState -> FreshState
execFresh (FreshT m) used = execState m used
