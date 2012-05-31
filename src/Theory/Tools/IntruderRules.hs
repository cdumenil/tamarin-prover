{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns     #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
  -- spurious warnings for view patterns
-- |
-- Copyright   : (c) 2010-2012 Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Benedikt Schmidt <beschmi@gmail.com>
-- Portability : GHC only
--
module Theory.Tools.IntruderRules (
    subtermIntruderRules
  , dhIntruderRules
  , specialIntruderRules
--  , xorIntruderRules -- there are no multiset intruder rules
  ) where

import           Control.Basics
import           Control.Monad.Fresh
import           Control.Monad.Reader

import qualified Data.ByteString.Char8           as BC
import           Data.List
import qualified Data.Set                        as S

import           Extension.Data.Label

import           Utils.Misc

import           Term.Maude.Signature
import           Term.Narrowing.Variants.Compute
import           Term.Positions
import           Term.Rewriting.Norm
import           Term.SubtermRule

import           Theory.Model



-- Variants of intruder deduction rules
----------------------------------------------------------------------


------------------------------------------------------------------------------
-- Special Intruder rules
------------------------------------------------------------------------------

{-
These are the special intruder that are always included.

rule (modulo AC) coerce:
   [ KD( f_, x ) ] --[ KU( f_, x) ]-> [ KU( f_, x ) ]

rule (modulo AC) pub:
   [ ] --[ KU( f_, $x) ]-> [ KU( f_, $x ) ]

rule (modulo AC) gen_fresh:
   [ Fr( ~x ) ] --[ KU( 'noexp', ~x ) ]-> [ KU( 'noexp', ~x ) ]

rule (modulo AC) isend:
   [ KU( f_, x) ] --[ K(x) ]-> [ In(x) ]

rule (modulo AC) irecv:
   [ Out( x) ] --> [ KD( 'exp', x) ]

-}
specialIntruderRules :: [IntrRuleAC]
specialIntruderRules =
    [ kuRule CoerceRule      [Fact KDFact [f_var, x_var]]   [f_var, x_var]
    , kuRule PubConstrRule   []                             [f_var, x_pub_var]
    , kuRule FreshConstrRule [Fact FreshFact [x_fresh_var]] [f_var, x_fresh_var]
    , Rule ISendRule
          [Fact KUFact [f_var, x_var]]
          [Fact InFact [x_var]]
          [kLogFact x_var]
    , Rule IRecvRule
          [Fact OutFact [x_var]]
          [Fact KDFact [expTagToTerm CanExp, x_var]]
          []
    ]
  where
    kuRule name prems ts = Rule name prems [Fact KUFact ts] [Fact KUFact ts]

    f_var       = varTerm (LVar "f_" LSortMsg   0)
    x_var       = varTerm (LVar "x"  LSortMsg   0)
    x_pub_var   = varTerm (LVar "x"  LSortPub   0)
    x_fresh_var = varTerm (LVar "x"  LSortFresh 0)


------------------------------------------------------------------------------
-- Subterm Intruder theory
------------------------------------------------------------------------------

destructionRules :: StRule -> [IntrRuleAC]
destructionRules (StRule lhs@(viewTerm -> FApp (NonAC (f,_)) _) (RhsPosition pos)) =
    go [] lhs pos
  where
    rhs = lhs `atPos` pos
    go _      _                       []     = []
    -- term already in premises
    go _      (viewTerm -> FApp _ _)  (_:[]) = []
    go uprems (viewTerm -> FApp _ as) (i:p)  =
        irule ++ go uprems' t' p
      where
        uprems' = uprems++[ t | (j, t) <- zip [0..] as, i /= j ]
        t'      = as!!i
        irule = if (t' /= rhs && rhs `notElem` uprems')
                 then (`evalFresh` avoid ([rhs,t']++uprems')) $ do
                     dfact <- kdFact Nothing t'
                     ufacts <- mapM (kuFact Nothing) uprems'
                     concfact <- kdFact (Just CanExp) rhs
                     return [ Rule (DestrRule (BC.unpack f)) (dfact:ufacts) [concfact] [] ]
                 else []
    go _      (viewTerm -> Lit _)     (_:_)  =
        error "IntruderRules.destructionRules: impossible, position invalid"

destructionRules _ = []

-- | Simple removal of subsumed rules for auto-generated free intruder rules.
minimizeIntruderRules :: [IntrRuleAC] -> [IntrRuleAC]
minimizeIntruderRules rules =
    go [] rules
  where
    go checked [] = reverse checked
    go checked (r@(Rule _ prems concs _):unchecked) = go checked' unchecked
      where
        checked' = if any (\(Rule _ prems' concs' _)
                               -> map dropExpTag concs' == map dropExpTag concs &&
                                  map dropExpTag prems' `subsetOf` map dropExpTag prems)
                          (checked++unchecked)
                   then checked
                   else (r:checked)

-- | @freeIntruderRules rus@ returns the set of intruder rules for
--   the free (not Xor, DH, and MSet) part of the given signature.
subtermIntruderRules :: MaudeSig -> [IntrRuleAC]
subtermIntruderRules maudeSig =
     minimizeIntruderRules $ concatMap destructionRules (S.toList $ stRules maudeSig)
     ++ constructionRules (functionSymbols maudeSig)

constructionRules :: FunSig -> [IntrRuleAC]
constructionRules fSig =
    [ createRule s k | (s,k) <- S.toList fSig ]
  where
    createRule s k = (`evalFresh` nothingUsed) $ do
        vars     <- map varTerm <$> (sequence $ replicate k (freshLVar "x" LSortMsg))
        pfacts   <- mapM (kuFact Nothing) vars
        let m = fApp (NonAC (s,k)) vars
        concfact <- kuFact (Just CanExp) m
        return $ Rule (ConstrRule (BC.unpack s)) pfacts [concfact] [concfact]

dropExpTag :: Fact a -> Fact a
dropExpTag (Fact KUFact [_e,m]) = Fact KUFact [m]
dropExpTag (Fact KDFact [_e,m]) = Fact KDFact [m]
dropExpTag t                    = t

------------------------------------------------------------------------------
-- Diffie-Hellman Intruder Rules
------------------------------------------------------------------------------

dhIntruderRules :: WithMaude [IntrRuleAC]
dhIntruderRules = reader $ \hnd -> minimizeIntruderRules $
    [ expRule ConstrRule kuFact return
    , invRule ConstrRule kuFact return
    ] ++
    concatMap (variantsIntruder hnd)
      [ expRule DestrRule kdFact (const [])
      , invRule DestrRule kdFact (const [])
      ]
  where
    expRule mkInfo kudFact mkAction = (`evalFresh` nothingUsed) $ do
        b        <- varTerm <$> freshLVar "x" LSortMsg
        e        <- varTerm <$> freshLVar "x" LSortMsg
        bfact    <- kudFact (Just CanExp) b
        efact    <- kuFact Nothing e
        let conc = fAppExp (b, e)
        concfact <- kudFact (Just CannotExp) conc
        return $ Rule (mkInfo "exp") [bfact, efact] [concfact] (mkAction concfact)

    invRule mkInfo kudFact mkAction = (`evalFresh` nothingUsed) $ do
        x        <- varTerm <$> freshLVar "x" LSortMsg
        bfact    <- kudFact Nothing x
        let conc = fAppInv x
        concfact <- kudFact (Just CanExp) conc
        return $ Rule (mkInfo "inv") [bfact] [concfact] (mkAction concfact)


variantsIntruder :: MaudeHandle -> IntrRuleAC -> [IntrRuleAC]
variantsIntruder hnd ru = do
    let concTerms = concatMap factTerms
                              (get rPrems ru++get rConcs ru++get rActs ru)
    fsigma <- computeVariants (fAppList concTerms) `runReader` hnd
    let sigma     = freshToFree fsigma `evalFreshAvoiding` concTerms
        ruvariant = normRule' (apply sigma ru) `runReader` hnd
    guard (frees (get rConcs ruvariant) /= [] &&
           -- ground terms are already deducible by applying construction rules
           ruvariant /= ru &&
           -- this is a construction rule
           (map dropExpTag (get rConcs ruvariant))
           \\ (map dropExpTag (get rPrems ruvariant)) /= []
           -- The conclusion is included in the premises
           )

    case concatMap factTerms $ get rConcs ruvariant of
        [_, viewTerm -> FApp (AC Mult) _] ->
            fail "Rules with product conclusion are redundant"
        _                     -> return ruvariant


normRule' :: IntrRuleAC -> WithMaude IntrRuleAC
normRule' (Rule i ps cs as) = reader $ \hnd ->
    let normFactTerms = map (fmap (\t -> norm' t `runReader` hnd)) in
    Rule i (normFactTerms ps) (normFactTerms cs) (normFactTerms as)



{-
------------------------------------------------------------------------------
-- Xor Intruder Rules
------------------------------------------------------------------------------

xorIntruderRules :: WithMaude [IntrRuleAC]
xorIntruderRules = return []
  -- TODO: extend XOR tagging

maude :: IO MaudeHandle
maude = startMaude "maude" allMaudeSig

t :: IO ()
t = do
  m <- maude
  let rules = dhIntruderRules `runReader` m
  mapM_ (putStrLn . render . prettyIntrRuleAC) rules
  writeFile "/tmp/dhrules" $ unlines (map ((++"\n"). render . prettyIntrRuleAC) rules)
  putStrLn ("\nThere are " ++ show (length rules)
            ++ " and " ++ show (length rules - 3) ++ " of these are exp-down rules")
-}
