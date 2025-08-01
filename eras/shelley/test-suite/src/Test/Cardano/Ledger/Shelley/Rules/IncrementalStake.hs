{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Test.Cardano.Ledger.Shelley.Rules.IncrementalStake (
  incrStakeComputationTest,
  incrStakeComparisonTest,
  stakeDistr,
  aggregateUtxoCoinByCredential,
) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Coin
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Core
import Cardano.Ledger.Credential (Credential (..), Ptr, StakeReference (StakeRefBase, StakeRefPtr))
import Cardano.Ledger.Shelley.Core
import Cardano.Ledger.Shelley.LedgerState (
  EpochState (..),
  LedgerState (..),
  NewEpochState (..),
  UTxOState (..),
  curPParamsEpochStateL,
 )
import Cardano.Ledger.Shelley.State
import qualified Cardano.Ledger.UMap as UM
import Control.SetAlgebra (dom, eval, (▷), (◁))
import Data.Foldable (fold)
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy
import qualified Data.VMap as VMap
import Lens.Micro hiding (ix)
import Test.Cardano.Ledger.Shelley.ConcreteCryptoTypes (MockCrypto)
import Test.Cardano.Ledger.Shelley.Constants (defaultConstants)
import Test.Cardano.Ledger.Shelley.Generator.Core (GenEnv)
import Test.Cardano.Ledger.Shelley.Generator.EraGen (EraGen (..))
import Test.Cardano.Ledger.Shelley.Generator.ShelleyEraGen ()
import Test.Cardano.Ledger.Shelley.Rules.Chain (CHAIN, ChainState (..))
import Test.Cardano.Ledger.Shelley.Rules.TestChain (
  TestingLedger,
  forAllChainTrace,
  ledgerTraceFromBlock,
  longTraceLen,
  traceLen,
 )
import Test.Cardano.Ledger.Shelley.Utils (
  ChainProperty,
 )
import Test.Cardano.Ledger.TerseTools (tersemapdiffs)
import Test.Control.State.Transition.Trace (
  SourceSignalTarget (..),
  sourceSignalTargets,
 )
import qualified Test.Control.State.Transition.Trace.Generator.QuickCheck as QC
import Test.QuickCheck (
  Property,
  conjoin,
  counterexample,
  (===),
 )
import Test.Tasty (TestTree)
import Test.Tasty.QuickCheck (testProperty)

incrStakeComputationTest ::
  forall era ledger.
  ( EraGen era
  , EraStake era
  , InstantStake era ~ ShelleyInstantStake era
  , TestingLedger era ledger
  , ChainProperty era
  , QC.HasTrace (CHAIN era) (GenEnv MockCrypto era)
  ) =>
  TestTree
incrStakeComputationTest =
  testProperty "instant stake calculation" $
    forAllChainTrace @era longTraceLen defaultConstants $ \tr -> do
      let ssts = sourceSignalTargets tr

      conjoin . concat $
        [ -- preservation properties
          map (incrStakeComp @era @ledger) ssts
        ]

incrStakeComp ::
  forall era ledger.
  ( ChainProperty era
  , InstantStake era ~ ShelleyInstantStake era
  , TestingLedger era ledger
  ) =>
  SourceSignalTarget (CHAIN era) ->
  Property
incrStakeComp SourceSignalTarget {source = chainSt, signal = block} =
  conjoin $
    map checkIncrStakeComp $
      sourceSignalTargets ledgerTr
  where
    (_, ledgerTr) = ledgerTraceFromBlock @era @ledger chainSt block
    checkIncrStakeComp :: SourceSignalTarget ledger -> Property
    checkIncrStakeComp
      SourceSignalTarget
        { source = LedgerState UTxOState {utxosUtxo = u, utxosInstantStake = is} dp
        , signal = tx
        , target = LedgerState UTxOState {utxosUtxo = u', utxosInstantStake = is'} dp'
        } =
        counterexample
          ( unlines
              [ "\nDetails:"
              , "\ntx"
              , show tx
              , "size original utxo"
              , show (Map.size $ unUTxO u)
              , "original utxo"
              , show u
              , "original instantStake"
              , show is
              , "final utxo"
              , show u'
              , "final instantStake"
              , show is'
              , "original ptrs"
              , show ptrs
              , "final ptrs"
              , show ptrs'
              ]
          )
          $ utxoBalanace === fromCompact instantStakeBalanace
        where
          utxoBalanace = sumCoinUTxO u'
          instantStakeBalanace = fold (sisCredentialStake is') <> fold (sisPtrStake is')
          ptrs = ptrsMap $ dp ^. certDStateL
          ptrs' = ptrsMap $ dp' ^. certDStateL

incrStakeComparisonTest ::
  forall era.
  ( EraGen era
  , EraGov era
  , EraStake era
  , QC.HasTrace (CHAIN era) (GenEnv MockCrypto era)
  ) =>
  Proxy era ->
  TestTree
incrStakeComparisonTest Proxy =
  testProperty "Incremental stake distribution at epoch boundaries agrees" $
    forAllChainTrace traceLen defaultConstants $ \tr ->
      conjoin $
        map (\(SourceSignalTarget _ target _) -> checkIncrementalStake @era ((nesEs . chainNes) target)) $
          filter (not . sameEpoch) (sourceSignalTargets tr)
  where
    sameEpoch SourceSignalTarget {source, target} = epoch source == epoch target
    epoch = nesEL . chainNes

checkIncrementalStake ::
  forall era.
  (EraGov era, EraTxOut era, EraStake era, EraCertState era) =>
  EpochState era ->
  Property
checkIncrementalStake es =
  let
    LedgerState (UTxOState utxo _ _ _ instantStake _) certState = esLState es
    dstate = certState ^. certDStateL
    pstate = certState ^. certPStateL
    stake = stakeDistr @era utxo dstate pstate
    snapShot = snapShotFromInstantStake instantStake dstate pstate
    _pp = es ^. curPParamsEpochStateL
   in
    counterexample
      ( "\nIncremental stake distribution does not match old style stake distribution"
          ++ tersediffincremental "differences: Old vs Incremental" (ssStake stake) (ssStake snapShot)
      )
      (stake === snapShot)

tersediffincremental :: String -> Stake -> Stake -> String
tersediffincremental message (Stake a) (Stake c) =
  tersemapdiffs (message ++ " " ++ "hashes") (mp a) (mp c)
  where
    mp = Map.map fromCompact . VMap.toMap

-- | Compute the current Stake Distribution. This was called at the Epoch boundary in the Snap Rule.
--   Now it is called in the tests to see that its incremental analog 'incrementalStakeDistr' agrees.
stakeDistr ::
  forall era.
  EraTxOut era =>
  UTxO era ->
  DState era ->
  PState era ->
  SnapShot
stakeDistr u ds ps =
  SnapShot
    (Stake $ VMap.fromMap (UM.compactCoinOrError <$> eval (dom activeDelegs ◁ stakeRelation)))
    (VMap.fromMap delegs)
    (VMap.fromMap poolParams)
  where
    rewards' :: Map.Map (Credential 'Staking) Coin
    rewards' = UM.rewardMap (dsUnified ds)
    delegs :: Map.Map (Credential 'Staking) (KeyHash 'StakePool)
    delegs = UM.sPoolMap (dsUnified ds)
    ptrs' = ptrsMap ds
    PState {psStakePoolParams = poolParams} = ps
    stakeRelation :: Map (Credential 'Staking) Coin
    stakeRelation = aggregateUtxoCoinByCredential ptrs' u rewards'
    activeDelegs :: Map.Map (Credential 'Staking) (KeyHash 'StakePool)
    activeDelegs = eval ((dom rewards' ◁ delegs) ▷ dom poolParams)

-- | Sum up all the Coin for each staking Credential. This function has an
--   incremental analog. See 'incrementalAggregateUtxoCoinByCredential'
aggregateUtxoCoinByCredential ::
  forall era.
  EraTxOut era =>
  Map Ptr (Credential 'Staking) ->
  UTxO era ->
  Map (Credential 'Staking) Coin ->
  Map (Credential 'Staking) Coin
aggregateUtxoCoinByCredential ptrs (UTxO u) initial =
  Map.foldl' accum (Map.filter (/= mempty) initial) u
  where
    accum ans out =
      let c = out ^. coinTxOutL
       in case out ^. addrTxOutL of
            Addr _ _ (StakeRefPtr p)
              | Just cred <- Map.lookup p ptrs -> Map.insertWith (<>) cred c ans
            Addr _ _ (StakeRefBase hk) -> Map.insertWith (<>) hk c ans
            _other -> ans
