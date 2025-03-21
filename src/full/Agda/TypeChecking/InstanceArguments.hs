{-# OPTIONS_GHC -Wunused-imports #-}

{-# LANGUAGE NondecreasingIndentation #-}

module Agda.TypeChecking.InstanceArguments
  ( findInstance
  , isInstanceConstraint
  , solveAwakeInstanceConstraints
  , shouldPostponeInstanceSearch
  , postponeInstanceConstraints
  , getInstanceCandidates
  , OutputTypeName(..)
  , getOutputTypeName
  , addTypedInstance
  , resolveInstanceHead
  ) where

import Control.Monad        ( forM )
import Control.Monad.Except ( ExceptT(..), runExceptT, MonadError(..) )
import Control.Monad.Trans  ( lift )

import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List as List
import Data.Function (on)
import Data.Monoid hiding ((<>))
import Data.Foldable (foldrM)

import Agda.Interaction.Options (optQualifiedInstances)

import Agda.Syntax.Common
import Agda.Syntax.Concrete.Name (isQualified)
import Agda.Syntax.Position
import Agda.Syntax.Internal as I
import Agda.Syntax.Internal.MetaVars
import Agda.Syntax.Scope.Base (isNameInScope, inverseScopeLookupName', AllowAmbiguousNames(..))

import Agda.TypeChecking.Conversion.Pure (pureEqualTerm)
import Agda.TypeChecking.Errors () --instance only
import Agda.TypeChecking.Implicit (implicitArgs)
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Records
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Warnings

import {-# SOURCE #-} Agda.TypeChecking.Constraints
import {-# SOURCE #-} Agda.TypeChecking.Conversion

import qualified Agda.Benchmarking as Benchmark
import Agda.TypeChecking.Monad.Benchmark (billTo)

import Agda.Utils.Lens
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Syntax.Common.Pretty (prettyShow)
import Agda.Utils.Null (empty)

import Agda.Utils.Impossible

-- | Compute a list of instance candidates.
--   'Nothing' if target type or any context type is a meta, error if
--   type is not eligible for instance search.
initialInstanceCandidates :: Type -> TCM (Either Blocker [Candidate])
initialInstanceCandidates t = do
  (_ , otn) <- getOutputTypeName t
  case otn of
    NoOutputTypeName -> typeError $ GenericError $
      "Instance search can only be used to find elements in a named type"
    OutputTypeNameNotYetKnown b -> do
      reportSDoc "tc.instance.cands" 30 $ "Instance type is not yet known. "
      return (Left b)
    OutputTypeVisiblePi -> typeError $ GenericError $
      "Instance search cannot be used to find elements in an explicit function type"
    OutputTypeVar    -> do
      reportSDoc "tc.instance.cands" 30 $ "Instance type is a variable. "
      runBlocked getContextVars
    OutputTypeName n -> do
      reportSDoc "tc.instance.cands" 30 $ "Found instance type head: " <+> prettyTCM n
      runBlocked getContextVars >>= \case
        Left b -> return $ Left b
        Right ctxVars -> Right . (ctxVars ++) <$> getScopeDefs n
  where
    -- get a list of variables with their type, relative to current context
    getContextVars :: BlockT TCM [Candidate]
    getContextVars = do
      ctx <- getContext
      reportSDoc "tc.instance.cands" 40 $ hang "Getting candidates from context" 2 (inTopContext $ prettyTCM $ PrettyContext ctx)
          -- Context variables with their types lifted to live in the full context
      let varsAndRaisedTypes = [ (var i, raise (i + 1) t) | (i, t) <- zip [0..] ctx ]
          vars = [ Candidate LocalCandidate x t (isOverlappable info)
                 | (x, Dom{domInfo = info, unDom = (_, t)}) <- varsAndRaisedTypes
                 , isInstance info
                 ]

      -- {{}}-fields of variables are also candidates
      let cxtAndTypes = [ (LocalCandidate, x, t) | (x, Dom{unDom = (_, t)}) <- varsAndRaisedTypes ]
      fields <- concat <$> mapM instanceFields (reverse cxtAndTypes)
      reportSDoc "tc.instance.fields" 30 $
        if null fields then "no instance field candidates" else
          "instance field candidates" $$ do
            nest 2 $ vcat
              [ sep [ (if overlap then "overlap" else empty) <+> prettyTCM c <+> ":"
                    , nest 2 $ prettyTCM t
                    ]
              | c@(Candidate q v t overlap) <- fields
              ]

      -- get let bindings
      env <- asksTC envLetBindings
      env <- mapM (traverse getOpen) $ Map.toList env
      let lets = [ Candidate LocalCandidate v t False
                 | (_, LetBinding _ v Dom{domInfo = info, unDom = t}) <- env
                 , isInstance info
                 , usableModality info
                 ]
      return $ vars ++ fields ++ lets

    etaExpand :: (MonadTCM m, PureTCM m)
              => Bool -> Type -> m (Maybe (QName, Args))
    etaExpand etaOnce t =
      isEtaRecordType t >>= \case
        Nothing | etaOnce -> do
          isRecordType t >>= \case
            Nothing         -> return Nothing
            Just (r, vs, _) -> do
              m <- currentModule
              -- Are we inside the record module? If so it's safe and desirable
              -- to eta-expand once (issue #2320).
              if qnameToList0 r `List.isPrefixOf` mnameToList m
                then return (Just (r, vs))
                else return Nothing
        r -> return r

    instanceFields :: (CandidateKind,Term,Type) -> BlockT TCM [Candidate]
    instanceFields = instanceFields' True

    instanceFields' :: Bool -> (CandidateKind,Term,Type) -> BlockT TCM [Candidate]
    instanceFields' etaOnce (q, v, t) =
      ifBlocked t (\ m _ -> patternViolation m) $ \ _ t -> do
      caseMaybeM (etaExpand etaOnce t) (return []) $ \ (r, pars) -> do
        (tel, args) <- lift $ forceEtaExpandRecord r pars v
        let types = map unDom $ applySubst (parallelS $ reverse $ map unArg args) (flattenTel tel)
        fmap concat $ forM (zip args types) $ \ (arg, t) ->
          ([ Candidate LocalCandidate (unArg arg) t (isOverlappable arg)
           | isInstance arg ] ++) <$>
          instanceFields' False (LocalCandidate, unArg arg, t)

    getScopeDefs :: QName -> TCM [Candidate]
    getScopeDefs n = do
      instanceDefs <- getInstanceDefs
      rel          <- viewTC eRelevance
      let qs = maybe [] Set.toList $ Map.lookup n instanceDefs
      catMaybes <$> mapM (candidate rel) qs

    candidate :: Relevance -> QName -> TCM (Maybe Candidate)
    candidate rel q = ifNotM (isNameInScope q <$> getScope) (return Nothing) $ do
      -- Jesper, 2020-03-16: When using --no-qualified-instances,
      -- filter out instances that are only in scope under a qualified
      -- name.
      filterQualified $ do
      -- Andreas, 2012-07-07:
      -- we try to get the info for q
      -- while opening a module, q may be in scope but not in the signature
      -- in this case, we just ignore q (issue 674)
      flip catchError handle $ do
        def <- getConstInfo q
        if not (getRelevance def `moreRelevant` rel) then return Nothing else do
          -- Andreas, 2017-01-14: instantiateDef is a bit of an overkill
          -- if we anyway get the freeVarsToApply
          -- WAS: t <- defType <$> instantiateDef def
          args <- freeVarsToApply q
          let t = defType def `piApply` args
              rel = getRelevance $ defArgInfo def
          let v = case theDef def of
               -- drop parameters if it's a projection function...
               Function{ funProjection = Right p } -> projDropParsApply p ProjSystem rel args
               -- Andreas, 2014-08-19: constructors cannot be declared as
               -- instances (at least as of now).
               -- I do not understand why the Constructor case is not impossible.
               -- Ulf, 2014-08-20: constructors are always instances.
               Constructor{ conSrcCon = c }       -> Con c ConOSystem []
               _                                  -> Def q $ map Apply args
          return $ Just $ Candidate (GlobalCandidate q) v t False
      where
        -- unbound constant throws an internal error
        handle (TypeError _ _ (Closure {clValue = InternalError _})) = return Nothing
        handle err                                                   = throwError err

        filterQualified :: TCM (Maybe Candidate) -> TCM (Maybe Candidate)
        filterQualified m = ifM (optQualifiedInstances <$> pragmaOptions) m $ do
          qc <- inverseScopeLookupName' AmbiguousAnything q <$> getScope
          let isQual = maybe True isQualified $ listToMaybe qc
          reportSDoc "tc.instance.qualified" 30 $
            if isQual then
              "dropping qualified instance" <+> prettyTCM q
            else
              "keeping instance" <+> prettyTCM q <+>
              "since it is in scope as" <+> prettyTCM qc
          if isQual then return Nothing else m


-- | @findInstance m (v,a)s@ tries to instantiate on of the types @a@s
--   of the candidate terms @v@s to the type @t@ of the metavariable @m@.
--   If successful, meta @m@ is solved with the instantiation of @v@.
--   If unsuccessful, the constraint is regenerated, with possibly reduced
--   candidate set.
--   The list of candidates is equal to @Nothing@ when the type of the meta
--   wasn't known when the constraint was generated. In that case, try to find
--   its type again.
findInstance :: MetaId -> Maybe [Candidate] -> TCM ()
findInstance m Nothing = do
  -- Andreas, 2015-02-07: New metas should be created with range of the
  -- current instance meta, thus, we set the range.
  mv <- lookupLocalMeta m
  setCurrentRange mv $ do
    reportSLn "tc.instance" 20 $ "The type of the FindInstance constraint isn't known, trying to find it again."
    t <- instantiate =<< getMetaTypeInContext m
    reportSLn "tc.instance" 70 $ "findInstance 1: t: " ++ prettyShow t

    -- Issue #2577: If the target is a function type the arguments are
    -- potential candidates, so we add them to the context to make
    -- initialInstanceCandidates pick them up.
    TelV tel t <- telViewUpTo' (-1) notVisible t
    cands <- addContext tel $ initialInstanceCandidates t
    case cands of
      Left unblock -> do
        reportSLn "tc.instance" 20 "Can't figure out target of instance goal. Postponing constraint."
        addConstraint unblock $ FindInstance m Nothing
      Right cs -> findInstance m (Just cs)

findInstance m (Just cands) =                          -- Note: if no blocking meta variable this will not unblock until the end of the mutual block
  whenJustM (findInstance' m cands) $ (\ (cands, b) -> addConstraint b $ FindInstance m $ Just cands)

-- | Entry point for `tcGetInstances` primitive
getInstanceCandidates :: MetaId -> TCM (Either Blocker [Candidate])
getInstanceCandidates m = wrapper where
  wrapper = do
    mv <- lookupLocalMeta m
    setCurrentRange mv $ do
      t <- instantiate =<< getMetaTypeInContext m
      TelV tel t' <- telViewUpTo' (-1) notVisible t
      addContext tel $ runExceptT (worker t')

  worker :: Type -> ExceptT Blocker TCM [Candidate]
  worker t' = do
    cands <- ExceptT (initialInstanceCandidates t')
    cands <- lift (checkCandidates m t' cands) <&> \case
      Nothing         -> cands
      Just (_, cands) -> fst <$> cands
    cands <- lift (foldrM insertCandidate [] cands)
    reportSDoc "tc.instance.sort" 20 $ nest 2 $ vcat
      [ "sorted candidates"
      , vcat [ "-" <+> (if overlap then "overlap" else empty) <+> prettyTCM c <+> ":" <+> prettyTCM t
             | c@(Candidate q v t overlap) <- cands ] ]
    pure cands

-- | @'doesCandidateSpecialise' c1 c2@ checks whether the instance candidate @c1@
-- /specialises/ the instance candidate @c2@, i.e., whether the type of
-- @c2@ is a substitution instance of @c1@'s type.
-- Only the final return type of the instances is considered: the
-- presence of unsolvable instance arguments in the types of @c1@ or
-- @c2@ does not affect the results of 'doesCandidateSpecialise'.
doesCandidateSpecialise :: Candidate -> Candidate -> TCM Bool
doesCandidateSpecialise c1@Candidate{candidateType = t1} c2@Candidate{candidateType = t2} = do
  -- We compare
  --    c1 : ∀ {Γ} → T
  -- against
  --    c2 : ∀ {Δ} → S
  -- by moving to the context Γ ⊢, so that any variables in T's type are
  -- "rigid", but *instantiating* S[?/Δ], so its variables are
  -- "flexible"; then calling the conversion checker.

  let
    handle _ = do
      reportSDoc "tc.instance.sort" 30 $ nest 2 "=> NOT specialisation"
      pure False

    wrap = flip catchError handle
          -- Turn failures into returning false
         . localTCState
         -- Discard any changes to the TC state (metas from
         -- instantiating t2, recursive instance constraints, etc)
         . postponeInstanceConstraints
         -- Don't spend any time looking for instances in the contexts

  TelV tel t1 <- telView t1
  addContext tel $ wrap $ do
    (args, t2) <- implicitArgs (-1) (\h -> notVisible h) t2

    reportSDoc "tc.instance.sort" 30 $ "Does" <+> prettyTCM c1 <+> "specialise" <+> (prettyTCM c2 <> "?")
    reportSDoc "tc.instance.sort" 60 $ vcat
      [ "Comparing candidate"
      , nest 2 (prettyTCM c1 <+> colon <+> prettyTCM t1)
      , "vs"
      , nest 2 (prettyTCM c2 <+> colon <+> prettyTCM t2)
      ]

    leqType t2 t1
    reportSDoc "tc.instance.sort" 30 $ nest 2 "=> IS specialisation"
    pure True

insertCandidate :: Candidate -> [Candidate] -> TCM [Candidate]
insertCandidate x []     = pure [x]
insertCandidate x (y:xs) = doesCandidateSpecialise x y >>= \case
  True  -> pure (x:y:xs)
  False -> (y:) <$> insertCandidate x xs

-- | Result says whether we need to add constraint, and if so, the set of
--   remaining candidates and an eventual blocking metavariable.
findInstance' :: MetaId -> [Candidate] -> TCM (Maybe ([Candidate], Blocker))
findInstance' m cands = ifM (isFrozen m) (do
    reportSLn "tc.instance" 20 "Refusing to solve frozen instance meta."
    return (Just (cands, neverUnblock))) $ do
  ifM shouldPostponeInstanceSearch (do
    reportSLn "tc.instance" 20 "Postponing possibly recursive instance search."
    return $ Just (cands, neverUnblock)) $ billTo [Benchmark.Typing, Benchmark.InstanceSearch] $ do
  -- Andreas, 2015-02-07: New metas should be created with range of the
  -- current instance meta, thus, we set the range.
  mv <- lookupLocalMeta m
  setCurrentRange mv $ do
      reportSLn "tc.instance" 15 $
        "findInstance 2: constraint: " ++ prettyShow m ++ "; candidates left: " ++ show (length cands)
      reportSDoc "tc.instance" 60 $ nest 2 $ vcat
        [ sep [ (if overlap then "overlap" else empty) <+> prettyTCM c <+> ":"
              , nest 2 $ prettyTCM t ] | c@(Candidate q v t overlap) <- cands ]
      reportSDoc "tc.instance" 70 $ "raw" $$ do
       nest 2 $ vcat
        [ sep [ (if overlap then "overlap" else empty) <+> prettyTCM c <+> ":"
              , nest 2 $ pretty t ] | c@(Candidate q v t overlap) <- cands ]
      t <- getMetaTypeInContext m
      reportSLn "tc.instance" 70 $ "findInstance 2: t: " ++ prettyShow t
      insidePi t $ \ t -> do
      reportSDoc "tc.instance" 15 $ "findInstance 3: t =" <+> prettyTCM t
      reportSLn "tc.instance" 70 $ "findInstance 3: t: " ++ prettyShow t

      mcands <-
        -- Temporarily remove other instance constraints to avoid
        -- redundant solution attempts
        holdConstraints (const isInstanceProblemConstraint) $
        checkCandidates m t cands

      debugConstraints
      case mcands of

        Just ([(_, err)], []) -> do
          reportSDoc "tc.instance" 15 $
            "findInstance 5: the only viable candidate failed..."
          throwError err
        Just (errs, []) -> do
          if null errs then reportSDoc "tc.instance" 15 $ "findInstance 5: no viable candidate found..."
                       else reportSDoc "tc.instance" 15 $ "findInstance 5: all viable candidates failed..."
          -- #3676: Sort the candidates based on the size of the range for the errors and
          --        set the range of the full error to the range of the most precise candidate
          --        error.
          let sortedErrs = List.sortBy (compare `on` precision) errs
                where precision (_, err) = maybe infinity iLength $ rangeToInterval $ getRange err
                      infinity = 1000000000
          setCurrentRange (take 1 $ map snd sortedErrs) $
            typeError $ InstanceNoCandidate t [ (candidateTerm c, err) | (c, err) <- sortedErrs ]

        Just (_, [(c@(Candidate q term t' _), v)]) -> do

          reportSDoc "tc.instance" 15 $ vcat
            [ "instance search: attempting"
            , nest 2 $ prettyTCM m <+> ":=" <+> prettyTCM v
            ]
          reportSDoc "tc.instance" 70 $ nest 2 $
            "candidate v = " <+> pretty v
          ctxElims <- map Apply <$> getContextArgs
          equalTerm t (MetaV m ctxElims) v

          reportSDoc "tc.instance" 15 $ vcat
            [ "findInstance 5: solved by instance search using the only candidate"
            , nest 2 $ prettyTCM c <+> "=" <+> prettyTCM term
            , "of type " <+> prettyTCM t'
            , "for type" <+> prettyTCM t
            ]

          -- If we actually solved the constraints we should wake up any held
          -- instance constraints, to make sure we don't forget about them.
          wakeupInstanceConstraints
          return Nothing  -- We’re done

        _ -> do
          let cs = maybe cands (map fst . snd) mcands -- keep the current candidates if Nothing
          reportSDoc "tc.instance" 15 $
            text ("findInstance 5: refined candidates: ") <+>
            prettyTCM (List.map candidateTerm cs)
          return (Just (cs, neverUnblock))

insidePi :: Type -> (Type -> TCM a) -> TCM a
insidePi t ret = reduce (unEl t) >>= \case
    Pi a b     -> addContext (absName b, a) $ insidePi (absBody b) ret
    Def{}      -> ret t
    Var{}      -> ret t
    Sort{}     -> __IMPOSSIBLE__
    Con{}      -> __IMPOSSIBLE__
    Lam{}      -> __IMPOSSIBLE__
    Lit{}      -> __IMPOSSIBLE__
    Level{}    -> __IMPOSSIBLE__
    MetaV{}    -> __IMPOSSIBLE__
    DontCare{} -> __IMPOSSIBLE__
    Dummy s _  -> __IMPOSSIBLE_VERBOSE__ s

-- | Apply the computation to every argument in turn by reseting the state every
--   time. Return the list of the arguments giving the result True.
--
--   If the resulting list contains exactly one element, then the state is the
--   same as the one obtained after running the corresponding computation. In
--   all the other cases, the state is reset.
--
--   Also returns the candidates that pass type checking but fails constraints,
--   so that the error messages can be reported if there are no successful
--   candidates.
filterResetingState :: MetaId -> [Candidate] -> (Candidate -> TCM YesNo) -> TCM ([(Candidate, TCErr)], [(Candidate, Term)])
filterResetingState m cands f = do
  ctxArgs  <- getContextArgs
  let ctxElims = map Apply ctxArgs
  result <- mapM (\c -> do bs <- localTCStateSaving (f c); return (c, bs)) cands

  -- Check that there aren't any hard failures
  case [ err | (_, (HellNo err, _)) <- result ] of
    err : _ -> throwError err
    []      -> return ()

  -- c : Candidate
  -- r : YesNo
  -- a : Type         (fully instantiated)
  -- s : TCState
  let result' = [ (c, v, s) | (c, (r, s)) <- result, v <- maybeToList (fromYes r) ]
  result'' <- dropSameCandidates m result'
  case result'' of
    [(c, v, s)] -> ([], [(c,v)]) <$ putTC s
    _           -> do
      let bad  = [ (c, err) | (c, (NoBecause err, _)) <- result ]
          good = [ (c, v) | (c, v, _) <- result'' ]
      return (bad, good)

-- Drop all candidates which are judgmentally equal to the first one.
-- This is sufficient to reduce the list to a singleton should all be equal.
dropSameCandidates :: MetaId -> [(Candidate, Term, a)] -> TCM [(Candidate, Term, a)]
dropSameCandidates m cands0 = verboseBracket "tc.instance" 30 "dropSameCandidates" $ do
  !nextMeta    <- nextLocalMeta
  isRemoteMeta <- isRemoteMeta
  -- Does "it" contain any fresh meta-variables?
  let freshMetas =
        getAny .
        allMetas (\m -> Any (not (isRemoteMeta m || m < nextMeta)))

  -- Take overlappable candidates into account
  let cands =
        case List.partition (\ (c, _, _) -> candidateOverlappable c) cands0 of
          (cand : _, []) -> [cand]  -- only overlappable candidates: pick the first one
          _              -> cands0  -- otherwise require equality

  reportSDoc "tc.instance" 50 $ vcat
    [ "valid candidates:"
    , nest 2 $ vcat [ if freshMetas v then "(redacted)" else
                      sep [ prettyTCM v ]
                    | (_, v, _) <- cands ] ]
  rel <- getRelevance <$> lookupMetaModality m
  case cands of
    []            -> return cands
    cvd : _ | isIrrelevant rel -> do
      reportSLn "tc.instance" 30 "dropSameCandidates: Meta is irrelevant so any candidate will do."
      return [cvd]
    cvd@(_, v, _) : vas
      | freshMetas v -> do
          reportSLn "tc.instance" 30 "dropSameCandidates: Solution of instance meta has fresh metas so we don't filter equal candidates yet"
          return (cvd : vas)
      | otherwise -> (cvd :) <$> dropWhileM equal vas
      where
        equal :: (Candidate, Term, a) -> TCM Bool
        equal (_, v', _)
            | freshMetas v' = return False  -- If there are fresh metas we can't compare
            | otherwise     =
          verboseBracket "tc.instance" 30 "dropSameCandidates: " $ do
          reportSDoc "tc.instance" 30 $ sep [ prettyTCM v <+> "==", nest 2 $ prettyTCM v' ]
          a <- uncurry piApplyM =<< ((,) <$> getMetaType m <*> getContextArgs)
          runBlocked (pureEqualTerm a v v') <&> \case
            Left{}  -> False
            Right b -> b

data YesNo = Yes Term | No | NoBecause TCErr | HellNo TCErr
  deriving (Show)

fromYes :: YesNo -> Maybe Term
fromYes (Yes t) = Just t
fromYes _       = Nothing

-- | Given a meta @m@ of type @t@ and a list of candidates @cands@,
-- @checkCandidates m t cands@ returns a refined list of valid candidates and
-- candidates that failed some constraints.
checkCandidates :: MetaId -> Type -> [Candidate] -> TCM (Maybe ([(Candidate, TCErr)], [(Candidate, Term)]))
checkCandidates m t cands =
  verboseBracket "tc.instance.candidates" 20 ("checkCandidates " ++ prettyShow m) $
  ifM (anyMetaTypes cands) (return Nothing) $ Just <$> do
    reportSDoc "tc.instance.candidates" 20 $ nest 2 $ "target:" <+> prettyTCM t
    reportSDoc "tc.instance.candidates" 20 $ nest 2 $ vcat
      [ "candidates"
      , vcat [ "-" <+> (if overlap then "overlap" else empty) <+> prettyTCM c <+> ":" <+> prettyTCM t
             | c@(Candidate q v t overlap) <- cands ] ]
    cands' <- filterResetingState m cands (checkCandidateForMeta m t)
    reportSDoc "tc.instance.candidates" 20 $ nest 2 $ vcat
      [ "valid candidates"
      , vcat [ "-" <+> (if overlap then "overlap" else empty) <+> prettyTCM c <+> ":" <+> prettyTCM t
             | c@(Candidate q v t overlap) <- map fst (snd cands') ] ]
    reportSDoc "tc.instance.candidates" 60 $ nest 2 $ vcat
      [ "valid candidates"
      , vcat [ "-" <+> (if overlap then "overlap" else empty) <+> prettyTCM v <+> ":" <+> prettyTCM t
             | c@(Candidate q v t overlap) <- map fst (snd cands') ] ]
    return cands'
  where
    anyMetaTypes :: [Candidate] -> TCM Bool
    anyMetaTypes [] = return False
    anyMetaTypes (Candidate _ _ a _ : cands) = do
      a <- instantiate a
      case unEl a of
        MetaV{} -> return True
        _       -> anyMetaTypes cands

    checkDepth :: Term -> Type -> TCM YesNo -> TCM YesNo
    checkDepth c a k = locallyTC eInstanceDepth succ $ do
      d        <- viewTC eInstanceDepth
      maxDepth <- maxInstanceSearchDepth
      when (d > maxDepth) $ typeError $ InstanceSearchDepthExhausted c a maxDepth
      k

    checkCandidateForMeta :: MetaId -> Type -> Candidate -> TCM YesNo
    checkCandidateForMeta m t (Candidate q term t' _) = checkDepth term t' $ do
      -- Andreas, 2015-02-07: New metas should be created with range of the
      -- current instance meta, thus, we set the range.
      mv <- lookupLocalMeta m
      setCurrentRange mv $ runCandidateCheck $
        verboseBracket "tc.instance" 20 ("checkCandidateForMeta " ++ prettyShow m) $ do
          reportSDoc "tc.instance" 20 $ vcat
            [ "checkCandidateForMeta"
            , "  t    =" <+> prettyTCM t
            , "  t'   =" <+> prettyTCM t'
            , "  term =" <+> prettyTCM term
            ]
          reportSDoc "tc.instance" 70 $ vcat
            [ "  t    =" <+> pretty t
            , "  t'   =" <+> pretty t'
            , "  term =" <+> pretty term
            ]
          debugConstraints

          -- Apply hidden and instance arguments (in case of
          -- --overlapping-instances, this performs recursive
          -- inst. search!).
          (args, t'') <- implicitArgs (-1) (\h -> notVisible h) t'

          reportSDoc "tc.instance" 20 $
            "instance search: checking" <+> prettyTCM t'' <+> "<=" <+> prettyTCM t
          reportSDoc "tc.instance" 70 $ vcat
            [ "instance search: checking (raw)"
            , nest 4 $ pretty t''
            , nest 2 $ "<="
            , nest 4 $ pretty t
            ]
          leqType t'' t
          debugConstraints

          flip catchError (return . NoBecause) $ do
            -- make a pass over constraints, to detect cases where
            -- some are made unsolvable by the type comparison, but
            -- don't do this for FindInstance's to prevent loops.
            solveAwakeConstraints' True
            -- We need instantiateFull here to remove 'local' metas
            v <- instantiateFull =<< (term `applyDroppingParameters` args)
            reportSDoc "tc.instance" 15 $
              sep [ ("instance search: found solution for" <+> prettyTCM m) <> ":"
                  , nest 2 $ prettyTCM v ]
            return $ Yes v
      where
        runCandidateCheck = flip catchError handle . nowConsideringInstance

        hardFailure :: TCErr -> Bool
        hardFailure (TypeError _ _ err) =
          case clValue err of
            InstanceSearchDepthExhausted{} -> True
            _                              -> False
        hardFailure _ = False

        handle :: TCErr -> TCM YesNo
        handle err
          | hardFailure err = return $ HellNo err
          | otherwise       = do
              reportSDoc "tc.instance" 50 $ "candidate failed type check:" <+> prettyTCM err
              return No


nowConsideringInstance :: (ReadTCState m) => m a -> m a
nowConsideringInstance = locallyTCState stConsideringInstance $ const True

isInstanceProblemConstraint :: ProblemConstraint -> Bool
isInstanceProblemConstraint = isInstanceConstraint . clValue . theConstraint

wakeupInstanceConstraints :: TCM ()
wakeupInstanceConstraints =
  unlessM shouldPostponeInstanceSearch $ do
    wakeConstraints (wakeUpWhen_ isInstanceProblemConstraint)
    solveAwakeInstanceConstraints

solveAwakeInstanceConstraints :: TCM ()
solveAwakeInstanceConstraints =
  solveSomeAwakeConstraints isInstanceProblemConstraint False

postponeInstanceConstraints :: TCM a -> TCM a
postponeInstanceConstraints m =
  locallyTCState stPostponeInstanceSearch (const True) m <* wakeupInstanceConstraints

-- | To preserve the invariant that a constructor is not applied to its
--   parameter arguments, we explicitly check whether function term
--   we are applying to arguments is a unapplied constructor.
--   In this case we drop the first 'conPars' arguments.
--   See Issue670a.
--   Andreas, 2013-11-07 Also do this for projections, see Issue670b.
applyDroppingParameters :: Term -> Args -> TCM Term
applyDroppingParameters t vs = do
  let fallback = return $ t `apply` vs
  case t of
    Con c ci [] -> do
      def <- theDef <$> getConInfo c
      case def of
        Constructor {conPars = n} -> return $ Con c ci (map Apply $ drop n vs)
        _ -> __IMPOSSIBLE__
    Def f [] -> do
      -- Andreas, 2022-03-07, issue #5809: don't drop parameters of irrelevant projections.
      mp <- isRelevantProjection f
      case mp of
        Just Projection{projIndex = n} -> do
          case drop n vs of
            []     -> return t
            u : us -> (`apply` us) <$> applyDef ProjPrefix f u
        _ -> fallback
    _ -> fallback

---------------------------------------------------------------------------
-- * Instance definitions
---------------------------------------------------------------------------

data OutputTypeName
  = OutputTypeName QName
  | OutputTypeVar
  | OutputTypeVisiblePi
  | OutputTypeNameNotYetKnown Blocker
  | NoOutputTypeName

-- | Strips all hidden and instance Pi's and return the argument
--   telescope and head definition name, if possible.
getOutputTypeName :: Type -> TCM (Telescope, OutputTypeName)
-- 2023-10-26, Jesper, issue #6941: To make instance search work correctly for
-- abstract or opaque instances, we need to ignore abstract mode when computing
-- the output type name.
getOutputTypeName t = ignoreAbstractMode $ do
  TelV tel t' <- telViewUpTo' (-1) notVisible t
  ifBlocked (unEl t') (\ b _ -> return (tel , OutputTypeNameNotYetKnown b)) $ \ _ v ->
    case v of
      -- Possible base types:
      Def n _  -> return (tel , OutputTypeName n)
      Sort{}   -> return (tel , NoOutputTypeName)
      Var n _  -> return (tel , OutputTypeVar)
      Pi{}     -> return (tel , OutputTypeVisiblePi)
      -- Not base types:
      Con{}    -> __IMPOSSIBLE__
      Lam{}    -> __IMPOSSIBLE__
      Lit{}    -> __IMPOSSIBLE__
      Level{}  -> __IMPOSSIBLE__
      MetaV{}  -> __IMPOSSIBLE__
      DontCare{} -> __IMPOSSIBLE__
      Dummy s _ -> __IMPOSSIBLE_VERBOSE__ s


-- | Register the definition with the given type as an instance.
--   Issue warnings if instance is unusable.
addTypedInstance ::
     QName  -- ^ Name of instance.
  -> Type   -- ^ Type of instance.
  -> TCM ()
addTypedInstance = addTypedInstance' True

-- | Register the definition with the given type as an instance.
addTypedInstance' ::
     Bool   -- ^ Should we print warnings for unusable instance declarations?
  -> QName  -- ^ Name of instance.
  -> Type   -- ^ Type of instance.
  -> TCM ()
addTypedInstance' w x t = do
  (tel , n) <- getOutputTypeName t
  case n of
    OutputTypeName n            -> addNamedInstance x n
    OutputTypeNameNotYetKnown b -> do
      addUnknownInstance x
      addConstraint b $ ResolveInstanceHead x
    NoOutputTypeName            -> when w $ warning $ WrongInstanceDeclaration
    OutputTypeVar               -> when w $ warning $ WrongInstanceDeclaration
    OutputTypeVisiblePi         -> when w $ warning $ InstanceWithExplicitArg x

resolveInstanceHead :: QName -> TCM ()
resolveInstanceHead q = do
    clearUnknownInstance q
    -- Andreas, 2022-12-04, issue #6380:
    -- Do not warn about unusable instances here.
    addTypedInstance' False q =<< typeOfConst q

-- | Try to solve the instance definitions whose type is not yet known, report
--   an error if it doesn't work and return the instance table otherwise.
getInstanceDefs :: TCM InstanceTable
getInstanceDefs = do
  insts <- getAllInstanceDefs
  unless (null $ snd insts) $
    typeError $ GenericError $ "There are instances whose type is still unsolved"
  return $ fst insts
