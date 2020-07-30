{-# LANGUAGE TypeFamilies #-}  -- for type equality ~

module Agda.TypeChecking.Monad.Context where

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Control  ( MonadTransControl(..), liftThrough )

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Position
import {-# SOURCE #-} Agda.TypeChecking.Monad.Base

checkpointSubstitution :: MonadTCEnv tcm => CheckpointId -> tcm Substitution

class MonadTCEnv m => MonadAddContext m where
  addCtx :: Name -> Dom Type -> m a -> m a
  addCtx_ :: Name -> Dom TwinT -> m a -> m a
  addLetBinding' :: Name -> Term -> Dom Type -> m a -> m a
  updateContext :: Substitution -> (ContextHet -> ContextHet) -> m a -> m a
  withFreshName :: Range -> ArgName -> (Name -> m a) -> m a

  default addCtx
    :: (MonadAddContext n, MonadTransControl t, t n ~ m)
    => Name -> Dom Type -> m a -> m a
  addCtx x a = liftThrough $ addCtx x a

  default addCtx_
    :: (MonadAddContext n, MonadTransControl t, t n ~ m)
    => Name -> Dom TwinT -> m a -> m a
  addCtx_ x a = liftThrough $ addCtx_ x a

  default addLetBinding'
    :: (MonadAddContext n, MonadTransControl t, t n ~ m)
    => Name -> Term -> Dom Type -> m a -> m a
  addLetBinding' x u a = liftThrough $ addLetBinding' x u a

  default updateContext
    :: (MonadAddContext n, MonadTransControl t, t n ~ m)
    => Substitution -> (ContextHet -> ContextHet) -> m a -> m a
  updateContext sub f = liftThrough $ updateContext sub f

  default withFreshName
    :: (MonadAddContext n, MonadTransControl t, t n ~ m)
    => Range -> ArgName -> (Name -> m a) -> m a
  withFreshName r x cont = do
    st <- liftWith $ \ run -> do
      withFreshName r x $ run . cont
    restoreT $ return st

instance MonadAddContext m => MonadAddContext (ReaderT r m) where
instance MonadAddContext m => MonadAddContext (StateT r m) where

instance MonadAddContext TCM
