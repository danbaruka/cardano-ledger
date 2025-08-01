{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Conway.Governance (
  EraGov (..),
  EnactState (..),
  RatifyState (..),
  RatifyEnv (..),
  RatifySignal (..),
  ConwayGovState (..),
  predictFuturePParams,
  Committee (..),
  committeeMembersL,
  committeeThresholdL,
  authorizedElectedHotCommitteeCredentials,
  GovAction (..),
  GovActionState (..),
  GovActionIx (..),
  GovActionId (..),
  GovActionPurpose (..),
  ToGovActionPurpose,
  isGovActionWithPurpose,
  DRepPulsingState (..),
  DRepPulser (..),
  govActionIdToText,
  Voter (..),
  Vote (..),
  VotingProcedure (..),
  VotingProcedures (..),
  foldlVotingProcedures,
  foldrVotingProcedures,
  ProposalProcedure (..),
  Anchor (..),
  AnchorData (..),
  indexedGovProps,
  Constitution (..),
  ConwayEraGov (..),
  votingStakePoolThreshold,
  votingDRepThreshold,
  votingCommitteeThreshold,
  isStakePoolVotingAllowed,
  isDRepVotingAllowed,
  isCommitteeVotingAllowed,
  reorderActions,
  actionPriority,
  Proposals,
  mkProposals,
  unsafeMkProposals,
  GovPurposeId (..),
  PRoot (..),
  PEdges (..),
  PGraph (..),
  pRootsL,
  pPropsL,
  prRootL,
  prChildrenL,
  peChildrenL,
  pGraphL,
  pGraphNodesL,
  GovRelation (..),
  hoistGovRelation,
  withGovActionParent,
  toPrevGovActionIds,
  fromPrevGovActionIds,
  grPParamUpdateL,
  grHardForkL,
  grCommitteeL,
  grConstitutionL,
  proposalsActions,
  proposalsDeposits,
  proposalsAddAction,
  proposalsRemoveWithDescendants,
  proposalsAddVote,
  proposalsIds,
  proposalsApplyEnactment,
  proposalsSize,
  proposalsLookupId,
  proposalsActionsMap,
  proposalsWithPurpose,
  cgsProposalsL,
  cgsDRepPulsingStateL,
  cgsCurPParamsL,
  cgsPrevPParamsL,
  cgsFuturePParamsL,
  cgsCommitteeL,
  cgsConstitutionL,
  ensCommitteeL,
  ensConstitutionL,
  ensCurPParamsL,
  ensPrevPParamsL,
  ensWithdrawalsL,
  ensTreasuryL,
  ensPrevGovActionIdsL,
  ensPrevPParamUpdateL,
  ensPrevHardForkL,
  ensPrevCommitteeL,
  ensPrevConstitutionL,
  ensProtVerL,
  rsEnactStateL,
  rsExpiredL,
  rsEnactedL,
  rsDelayedL,
  constitutionScriptL,
  constitutionAnchorL,
  gasIdL,
  gasDepositL,
  gasCommitteeVotesL,
  gasDRepVotesL,
  gasStakePoolVotesL,
  gasExpiresAfterL,
  gasActionL,
  gasReturnAddrL,
  gasProposedInL,
  gasProposalProcedureL,
  gasDeposit,
  gasAction,
  gasReturnAddr,
  pProcDepositL,
  pProcGovActionL,
  pProcReturnAddrL,
  pProcAnchorL,
  newEpochStateDRepPulsingStateL,
  epochStateDRepPulsingStateL,
  epochStateStakeDistrL,
  epochStateRegDrepL,
  epochStateUMapL,
  pulseDRepPulsingState,
  completeDRepPulsingState,
  extractDRepPulsingState,
  forceDRepPulsingState,
  finishDRepPulser,
  computeDRepDistr,
  getRatifyState,
  conwayGovStateDRepDistrG,
  psDRepDistrG,
  PulsingSnapshot (..),
  setCompleteDRepPulsingState,
  setFreshDRepPulsingState,
  psProposalsL,
  psDRepDistrL,
  psDRepStateL,
  psPoolDistrL,
  RunConwayRatify (..),
  govStatePrevGovActionIds,
  mkEnactState,
  ratifySignalL,
  reDRepDistrL,
  reDRepStateL,
  reCurrentEpochL,
  reCommitteeStateL,
  DefaultVote (..),
  defaultStakePoolVote,
  translateProposals,

  -- * Exported for testing
  pparamsUpdateThreshold,
  TreeMaybe (..),
  toGovRelationTree,
  toGovRelationTreeEither,
  showGovActionType,
) where

import Cardano.Ledger.Address (RewardAccount (raCredential))
import Cardano.Ledger.BaseTypes (
  EpochNo (..),
  Globals (..),
  KeyValuePairs (..),
  StrictMaybe (..),
  ToKeyValuePairs (..),
  knownNonZero,
  mulNonZero,
  toIntegerNonZero,
  (%.),
 )
import Cardano.Ledger.Binary (
  DecCBOR (..),
  DecShareCBOR (..),
  EncCBOR (..),
  FromCBOR (..),
  Interns,
  ToCBOR (..),
  decNoShareCBOR,
  decodeRecordNamedT,
 )
import Cardano.Ledger.Binary.Coders (
  Encode (..),
  encode,
  (!>),
 )
import Cardano.Ledger.Binary.Plain (
  decodeWord8,
  encodeWord8,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Era (ConwayEra)
import Cardano.Ledger.Conway.Governance.DRepPulser
import Cardano.Ledger.Conway.Governance.Internal
import Cardano.Ledger.Conway.Governance.Procedures
import Cardano.Ledger.Conway.Governance.Proposals
import Cardano.Ledger.Conway.State
import Cardano.Ledger.Core
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.PoolParams (PoolParams (ppRewardAccount))
import Cardano.Ledger.Shelley.LedgerState (
  EpochState (..),
  NewEpochState (..),
  epochStateGovStateL,
  epochStatePoolParamsL,
  esLStateL,
  lsCertState,
  lsUTxOState,
  newEpochStateGovStateL,
 )
import Cardano.Ledger.UMap
import Cardano.Ledger.Val (Val (..))
import Control.DeepSeq (NFData (..))
import Control.Monad (guard)
import Control.Monad.Trans
import Control.Monad.Trans.Reader (ReaderT, ask)
import Data.Aeson (ToJSON (..), (.=))
import Data.Default (Default (..))
import Data.Foldable (Foldable (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import GHC.Generics (Generic)
import Lens.Micro
import Lens.Micro.Extras (view)
import NoThunks.Class (NoThunks (..))

-- | Conway governance state
data ConwayGovState era = ConwayGovState
  { cgsProposals :: !(Proposals era)
  , cgsCommittee :: !(StrictMaybe (Committee era))
  , cgsConstitution :: !(Constitution era)
  , cgsCurPParams :: !(PParams era)
  , cgsPrevPParams :: !(PParams era)
  , cgsFuturePParams :: !(FuturePParams era)
  , cgsDRepPulsingState :: !(DRepPulsingState era)
  -- ^ The 'cgsDRepPulsingState' field is a pulser that incrementally computes the stake
  -- distribution of the DReps over the Epoch following the close of voting at end of
  -- the previous Epoch. It assembles this with some of its other internal components
  -- into a (RatifyEnv era) when it completes, and then calls the RATIFY rule and
  -- eventually returns the updated RatifyState. The pulser is created at the Epoch
  -- boundary, but does no work until it is pulsed in the 'NEWEPOCH' rule, whenever the
  -- system is NOT at the epoch boundary.
  }
  deriving (Generic, Show)

deriving instance (EraPParams era, EraStake era) => Eq (ConwayGovState era)

cgsProposalsL :: Lens' (ConwayGovState era) (Proposals era)
cgsProposalsL = lens cgsProposals (\x y -> x {cgsProposals = y})

cgsDRepPulsingStateL :: Lens' (ConwayGovState era) (DRepPulsingState era)
cgsDRepPulsingStateL = lens cgsDRepPulsingState (\x y -> x {cgsDRepPulsingState = y})

cgsCommitteeL :: Lens' (ConwayGovState era) (StrictMaybe (Committee era))
cgsCommitteeL = lens cgsCommittee (\x y -> x {cgsCommittee = y})

cgsConstitutionL :: Lens' (ConwayGovState era) (Constitution era)
cgsConstitutionL = lens cgsConstitution (\x y -> x {cgsConstitution = y})

cgsCurPParamsL :: Lens' (ConwayGovState era) (PParams era)
cgsCurPParamsL = lens cgsCurPParams (\x y -> x {cgsCurPParams = y})

cgsPrevPParamsL :: Lens' (ConwayGovState era) (PParams era)
cgsPrevPParamsL = lens cgsPrevPParams (\x y -> x {cgsPrevPParams = y})

cgsFuturePParamsL :: Lens' (ConwayGovState era) (FuturePParams era)
cgsFuturePParamsL =
  lens cgsFuturePParams (\cgs futurePParams -> cgs {cgsFuturePParams = futurePParams})

govStatePrevGovActionIds :: ConwayEraGov era => GovState era -> GovRelation StrictMaybe
govStatePrevGovActionIds = view $ proposalsGovStateL . pRootsL . to toPrevGovActionIds

conwayGovStateDRepDistrG ::
  EraStake era => SimpleGetter (ConwayGovState era) (Map DRep (CompactForm Coin))
conwayGovStateDRepDistrG = to (psDRepDistr . fst . finishDRepPulser . cgsDRepPulsingState)

getRatifyState :: EraStake era => ConwayGovState era -> RatifyState era
getRatifyState (ConwayGovState {cgsDRepPulsingState}) = snd $ finishDRepPulser cgsDRepPulsingState

-- | This function updates the thunk, which will contain new PParams once evaluated or
-- Nothing when there was no update. At the same time if we already know the future of
-- PParams, then it will act as an identity function.
predictFuturePParams :: EraStake era => ConwayGovState era -> ConwayGovState era
predictFuturePParams govState =
  case cgsFuturePParams govState of
    NoPParamsUpdate -> govState
    DefinitePParamsUpdate _ -> govState
    _ ->
      govState
        { cgsFuturePParams = PotentialPParamsUpdate newFuturePParams
        }
  where
    -- This binding is not forced until a call to `solidifyNextEpochPParams` in the TICK
    -- rule two stability windows before the end of the epoch, therefore it is safe to
    -- create thunks here throughout the epoch
    newFuturePParams = do
      guard (any hasChangesToPParams (rsEnacted ratifyState))
      pure (ensCurPParams (rsEnactState ratifyState))
    ratifyState = extractDRepPulsingState (cgsDRepPulsingState govState)
    hasChangesToPParams gas =
      case pProcGovAction (gasProposalProcedure gas) of
        ParameterChange {} -> True
        HardForkInitiation {} -> True
        _ -> False

mkEnactState :: ConwayEraGov era => GovState era -> EnactState era
mkEnactState gs =
  EnactState
    { ensCommittee = gs ^. committeeGovStateL
    , ensConstitution = gs ^. constitutionGovStateL
    , ensCurPParams = gs ^. curPParamsGovStateL
    , ensPrevPParams = gs ^. prevPParamsGovStateL
    , ensTreasury = zero
    , ensWithdrawals = mempty
    , ensPrevGovActionIds = govStatePrevGovActionIds gs
    }

instance EraPParams era => DecShareCBOR (ConwayGovState era) where
  type
    Share (ConwayGovState era) =
      ( Interns (Credential 'Staking)
      , Interns (KeyHash 'StakePool)
      , Interns (Credential 'DRepRole)
      , Interns (Credential 'HotCommitteeRole)
      )
  decSharePlusCBOR =
    decodeRecordNamedT "ConwayGovState" (const 7) $ do
      cgsProposals <- decSharePlusCBOR
      cgsCommittee <- lift decCBOR
      cgsConstitution <- lift decCBOR
      cgsCurPParams <- lift decCBOR
      cgsPrevPParams <- lift decCBOR
      cgsFuturePParams <- lift decCBOR
      cgsDRepPulsingState <- decSharePlusCBOR
      pure ConwayGovState {..}

instance EraPParams era => DecCBOR (ConwayGovState era) where
  decCBOR = decNoShareCBOR

instance (EraPParams era, EraStake era) => EncCBOR (ConwayGovState era) where
  encCBOR ConwayGovState {..} =
    encode $
      Rec ConwayGovState
        !> To cgsProposals
        !> To cgsCommittee
        !> To cgsConstitution
        !> To cgsCurPParams
        !> To cgsPrevPParams
        !> To cgsFuturePParams
        !> To cgsDRepPulsingState

instance (EraPParams era, EraStake era) => ToCBOR (ConwayGovState era) where
  toCBOR = toEraCBOR @era

instance EraPParams era => FromCBOR (ConwayGovState era) where
  fromCBOR = fromEraCBOR @era

instance EraPParams era => Default (ConwayGovState era) where
  def = ConwayGovState def def def def def def (DRComplete def def)

instance (EraPParams era, NFData (InstantStake era)) => NFData (ConwayGovState era)

instance (EraPParams era, NoThunks (InstantStake era)) => NoThunks (ConwayGovState era)

deriving via
  KeyValuePairs (ConwayGovState era)
  instance
    (EraPParams era, EraStake era) => ToJSON (ConwayGovState era)

instance (EraPParams era, EraStake era) => ToKeyValuePairs (ConwayGovState era) where
  toKeyValuePairs cg@(ConwayGovState _ _ _ _ _ _ _) =
    let ConwayGovState {..} = cg
     in [ "proposals" .= cgsProposals
        , "nextRatifyState" .= extractDRepPulsingState cgsDRepPulsingState
        , "committee" .= cgsCommittee
        , "constitution" .= cgsConstitution
        , "currentPParams" .= cgsCurPParams
        , "previousPParams" .= cgsPrevPParams
        , "futurePParams" .= cgsFuturePParams
        ]

instance EraGov ConwayEra where
  type GovState ConwayEra = ConwayGovState ConwayEra

  curPParamsGovStateL = cgsCurPParamsL

  prevPParamsGovStateL = cgsPrevPParamsL

  futurePParamsGovStateL = cgsFuturePParamsL

  obligationGovState st =
    Obligations
      { oblProposal = foldMap' gasDeposit $ proposalsActions (st ^. cgsProposalsL)
      , oblDRep = Coin 0
      , oblStake = Coin 0
      , oblPool = Coin 0
      }

class (EraGov era, EraStake era) => ConwayEraGov era where
  constitutionGovStateL :: Lens' (GovState era) (Constitution era)
  proposalsGovStateL :: Lens' (GovState era) (Proposals era)
  drepPulsingStateGovStateL :: Lens' (GovState era) (DRepPulsingState era)
  committeeGovStateL :: Lens' (GovState era) (StrictMaybe (Committee era))

instance ConwayEraGov ConwayEra where
  constitutionGovStateL = cgsConstitutionL
  proposalsGovStateL = cgsProposalsL
  drepPulsingStateGovStateL = cgsDRepPulsingStateL
  committeeGovStateL = cgsCommitteeL

-- ===================================================================
-- Lenses for access to (DRepPulsingState era)

newEpochStateDRepPulsingStateL ::
  ConwayEraGov era => Lens' (NewEpochState era) (DRepPulsingState era)
newEpochStateDRepPulsingStateL =
  newEpochStateGovStateL . drepPulsingStateGovStateL

epochStateDRepPulsingStateL :: ConwayEraGov era => Lens' (EpochState era) (DRepPulsingState era)
epochStateDRepPulsingStateL = epochStateGovStateL . drepPulsingStateGovStateL

setCompleteDRepPulsingState ::
  GovState era ~ ConwayGovState era =>
  PulsingSnapshot era ->
  RatifyState era ->
  EpochState era ->
  EpochState era
setCompleteDRepPulsingState snapshot ratifyState epochState =
  epochState
    & epochStateGovStateL . cgsDRepPulsingStateL
      .~ DRComplete snapshot ratifyState

-- | Refresh the pulser in the EpochState using all the new data that is needed to compute
-- the RatifyState when pulsing completes.
setFreshDRepPulsingState ::
  ( GovState era ~ ConwayGovState era
  , Monad m
  , RunConwayRatify era
  , ConwayEraGov era
  , ConwayEraCertState era
  ) =>
  EpochNo ->
  PoolDistr ->
  EpochState era ->
  ReaderT Globals m (EpochState era)
setFreshDRepPulsingState epochNo stakePoolDistr epochState = do
  -- When we are finished with the pulser that was started at the last epoch boundary, we
  -- need to initialize a fresh DRep pulser. We do so by computing the pulse size and
  -- gathering the data, which we will snapshot inside the pulser. We expect approximately
  -- 10*k-many blocks to be produced each epoch, where `k` value is the stability
  -- window. We must ensure for secure operation of the Hard Fork Combinator that we have
  -- the new EnactState available `6k/f` slots before the end of the epoch, while
  -- spreading out stake distribution computation throughout the `4k/f` slots. In this
  -- formula `f` stands for the active slot coefficient, which means that there will be
  -- approximately `4k` blocks created during that period.
  globals <- ask
  let ledgerState = epochState ^. esLStateL
      utxoState = lsUTxOState ledgerState
      instantStake = utxoState ^. instantStakeG
      certState = lsCertState ledgerState
      dState = certState ^. certDStateL
      vState = certState ^. certVStateL
      govState = epochState ^. epochStateGovStateL
      props = govState ^. cgsProposalsL
      -- Maximum number of blocks we are allowed to roll back: usually a small positive number
      k = securityParameter globals -- On mainnet set to 2160
      umap = dsUnified dState
      umapSize = Map.size $ umElems umap
      pulseSize = max 1 (fromIntegral umapSize %. (knownNonZero @4 `mulNonZero` toIntegerNonZero k))
      govState' =
        predictFuturePParams $
          govState
            & cgsDRepPulsingStateL
              .~ DRPulsing
                ( DRepPulser
                    { dpPulseSize = floor pulseSize
                    , dpUMap = dsUnified dState
                    , dpIndex = 0 -- used as the index of the remaining UMap
                    , dpInstantStake = instantStake -- used as part of the snapshot
                    , dpStakePoolDistr = stakePoolDistr
                    , dpDRepDistr = Map.empty -- The partial result starts as the empty map
                    , dpDRepState = vsDReps vState
                    , dpCurrentEpoch = epochNo
                    , dpCommitteeState = vsCommitteeState vState
                    , dpEnactState =
                        mkEnactState govState
                          & ensTreasuryL .~ epochState ^. treasuryL
                    , dpProposals = proposalsActions props
                    , dpProposalDeposits = proposalsDeposits props
                    , dpGlobals = globals
                    , dpPoolParams = epochState ^. epochStatePoolParamsL
                    }
                )
  pure $ epochState & epochStateGovStateL .~ govState'

-- | Force computation of DRep stake distribution and figure out the next enact
-- state. This operation is useful in cases when access to new EnactState or DRep stake
-- distribution is needed more than once. It is safe to call this function at any
-- point. Whenever pulser is already in computed state this will be a noop.
forceDRepPulsingState :: ConwayEraGov era => NewEpochState era -> NewEpochState era
forceDRepPulsingState nes = nes & newEpochStateDRepPulsingStateL %~ completeDRepPulsingState

-- | Default vote that will be used for Stake Pool.
data DefaultVote
  = -- | Reward account is delegated to a @DRepKeyHash@, @DRepScriptHash@ or undelegated:
    --   default vote is @No@.
    DefaultNo
  | -- | Reward account is delegated to @DRepAlwaysAbstain@:
    --   default vote is @Abstain@, except for @HardForkInitiation@ actions.
    DefaultAbstain
  | -- | Reward account is delegated to @DRepAlwaysNoConfidence@:
    --   default vote is @Yes@ in case of a @NoConfidence@ action, otherwise @No@.
    DefaultNoConfidence
  deriving (Eq, Show)

instance FromCBOR DefaultVote where
  fromCBOR = do
    tag <- decodeWord8
    case tag of
      0 -> pure DefaultNo
      1 -> pure DefaultAbstain
      2 -> pure DefaultNoConfidence
      _ -> fail $ "Invalid DefaultVote tag " ++ show tag

instance ToCBOR DefaultVote where
  toCBOR DefaultNo = encodeWord8 0
  toCBOR DefaultAbstain = encodeWord8 1
  toCBOR DefaultNoConfidence = encodeWord8 2

instance EncCBOR DefaultVote

instance DecCBOR DefaultVote

defaultStakePoolVote ::
  -- | Specify the key hash of the pool whose default vote should be returned.
  KeyHash 'StakePool ->
  -- | Registered Stake Pools
  Map (KeyHash 'StakePool) PoolParams ->
  -- | Delegations of staking credneitals to a DRep
  Map (Credential 'Staking) DRep ->
  DefaultVote
defaultStakePoolVote poolId poolParams dRepDelegations =
  toDefaultVote $
    Map.lookup poolId poolParams >>= \d ->
      Map.lookup (raCredential $ ppRewardAccount d) dRepDelegations
  where
    toDefaultVote (Just DRepAlwaysAbstain) = DefaultAbstain
    toDefaultVote (Just DRepAlwaysNoConfidence) = DefaultNoConfidence
    toDefaultVote _ = DefaultNo

-- | Extract all unique hot credential authorizations for the current committee
-- that is elected.
authorizedElectedHotCommitteeCredentials ::
  StrictMaybe (Committee era) ->
  CommitteeState era ->
  Set.Set (Credential 'HotCommitteeRole)
authorizedElectedHotCommitteeCredentials committee committeeState =
  case committee of
    SNothing -> Set.empty
    SJust electedCommiteee ->
      authorizedHotCommitteeCredentials $
        CommitteeState $
          csCommitteeCreds committeeState `Map.intersection` committeeMembers electedCommiteee
