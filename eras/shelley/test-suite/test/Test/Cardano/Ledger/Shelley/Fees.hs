{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Cardano.Ledger.Shelley.Fees (
  sizeTests,
) where

import Cardano.Ledger.Address (Withdrawals (..))
import Cardano.Ledger.BaseTypes (
  Network (..),
  StrictMaybe (..),
  textToDns,
  textToUrl,
 )
import Cardano.Ledger.Binary.Plain as Plain (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core
import Cardano.Ledger.Keys (asWitness)
import Cardano.Ledger.PoolParams (PoolMetadata (..), StakePoolRelay (..))
import Cardano.Ledger.Shelley (ShelleyEra, TxBody (..))
import Cardano.Ledger.Shelley.API (
  Addr,
  Credential (..),
  PoolParams (..),
  RewardAccount (..),
  ShelleyTxOut (..),
  TxIn (..),
 )
import Cardano.Ledger.Shelley.Scripts (
  ShelleyEraScript,
  pattern RequireMOf,
  pattern RequireSignature,
 )
import Cardano.Ledger.Shelley.Tx (
  ShelleyTx (..),
 )
import Cardano.Ledger.Shelley.TxAuxData
import Cardano.Ledger.Shelley.TxCert (
  pattern DelegStakeTxCert,
  pattern RegTxCert,
  pattern UnRegTxCert,
 )
import Cardano.Ledger.Shelley.TxWits (
  addrWits,
 )
import Cardano.Ledger.Shelley.UTxO (getShelleyMinFeeTxUtxo)
import Cardano.Ledger.Slot (EpochNo (..), SlotNo (..))
import Cardano.Ledger.Tools (estimateMinFeeTx)
import Cardano.Ledger.TxIn (mkTxInPartial)
import qualified Cardano.Ledger.Val as Val
import Cardano.Protocol.Crypto (StandardCrypto, hashVerKeyVRF)
import qualified Data.ByteString.Base16.Lazy as Base16
import qualified Data.ByteString.Char8 as BS (pack)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map (empty, singleton)
import Data.Maybe (fromJust)
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set
import GHC.Stack (HasCallStack)
import Lens.Micro
import Test.Cardano.Ledger.Core.KeyPair (KeyPair (..), mkAddr, mkWitnessesVKey, vKey)
import Test.Cardano.Ledger.Shelley.Generator.Core (VRFKeyPair (..))
import Test.Cardano.Ledger.Shelley.Generator.EraGen (genesisId)
import Test.Cardano.Ledger.Shelley.Generator.ShelleyEraGen ()
import Test.Cardano.Ledger.Shelley.Utils (
  RawSeed (..),
  mkKeyPair,
  mkVRFKeyPair,
  unsafeBoundRational,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, testCase, (@?=))

sizeTest :: HasCallStack => BSL.ByteString -> ShelleyTx ShelleyEra -> Assertion
sizeTest b16 tx = do
  Base16.encode (Plain.serialize tx) @?= b16
  (tx ^. sizeTxF) @?= toInteger (BSL.length b16 `div` 2)

alicePay :: KeyPair 'Payment
alicePay = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 0 0 0 0 0)

aliceStake :: KeyPair 'Staking
aliceStake = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 0 0 0 0 1)

aliceSHK :: Credential 'Staking
aliceSHK = (KeyHashObj . hashKey . vKey) aliceStake

alicePool :: KeyPair 'StakePool
alicePool = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 0 0 0 0 2)

alicePoolKH :: KeyHash 'StakePool
alicePoolKH = hashKey $ vKey alicePool

alicePoolParams :: PoolParams
alicePoolParams =
  PoolParams
    { ppId = alicePoolKH
    , ppVrf = hashVerKeyVRF @StandardCrypto . vrfVerKey $ mkVRFKeyPair @StandardCrypto (RawSeed 0 0 0 0 3)
    , ppPledge = Coin 1
    , ppCost = Coin 5
    , ppMargin = unsafeBoundRational 0.1
    , ppRewardAccount = RewardAccount Testnet aliceSHK
    , ppOwners = Set.singleton $ (hashKey . vKey) aliceStake
    , ppRelays =
        StrictSeq.singleton $
          SingleHostName SNothing $
            fromJust $
              textToDns 64 "relay.io"
    , ppMetadata =
        SJust $
          PoolMetadata
            { pmUrl = fromJust $ textToUrl 64 "alice.pool"
            , pmHash = BS.pack "{}"
            }
    }

aliceAddr :: Addr
aliceAddr = mkAddr alicePay aliceStake

bobPay :: KeyPair 'Payment
bobPay = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 1 0 0 0 0)

bobStake :: KeyPair 'Staking
bobStake = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 1 0 0 0 1)

bobSHK :: Credential 'Staking
bobSHK = KeyHashObj . hashKey $ vKey bobStake

bobAddr :: Addr
bobAddr = mkAddr bobPay bobStake

carlPay :: KeyPair 'Payment
carlPay = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 2 0 0 0 0)

-- | Simple Transaction which consumes one UTxO and creates one UTxO
-- | and has one witness
txbSimpleUTxO :: TxBody ShelleyEra
txbSimpleUTxO =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.empty
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txSimpleUTxO :: ShelleyTx ShelleyEra
txSimpleUTxO =
  ShelleyTx
    { stBody = txbSimpleUTxO
    , stWits =
        mempty
          { addrWits = mkWitnessesVKey (hashAnnotated txbSimpleUTxO) [alicePay]
          }
    , stAuxData = SNothing
    }

txSimpleUTxOBytes16 :: BSL.ByteString
txSimpleUTxOBytes16 =
  "83a4008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030aa100818258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e584089c20cb6246483bbd0b2006f658597eff3e8ab3b8a6e9b22cb3c5b95cf0d3a2b96107acef88319fa2dd0fb28adcfdb330bb99f1f0058918a75d951ca9b73660cf6"

-- | Transaction which consumes two UTxO and creates five UTxO
-- | and has two witness
txbMutiUTxO :: TxBody ShelleyEra
txbMutiUTxO =
  ShelleyTxBody
    { stbInputs =
        Set.fromList
          [ mkTxInPartial genesisId 0
          , mkTxInPartial genesisId 1
          ]
    , stbOutputs =
        StrictSeq.fromList
          [ ShelleyTxOut aliceAddr (Val.inject $ Coin 10)
          , ShelleyTxOut aliceAddr (Val.inject $ Coin 20)
          , ShelleyTxOut aliceAddr (Val.inject $ Coin 30)
          , ShelleyTxOut bobAddr (Val.inject $ Coin 40)
          , ShelleyTxOut bobAddr (Val.inject $ Coin 50)
          ]
    , stbCerts = StrictSeq.empty
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 199
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txMutiUTxO :: ShelleyTx ShelleyEra
txMutiUTxO =
  ShelleyTx
    { stBody = txbMutiUTxO
    , stWits =
        mempty
          { addrWits =
              mkWitnessesVKey
                (hashAnnotated txbMutiUTxO)
                [ alicePay
                , bobPay
                ]
          }
    , stAuxData = SNothing
    }

txMutiUTxOBytes16 :: BSL.ByteString
txMutiUTxOBytes16 =
  "83a4008282582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c1113140082582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131401018582583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a82583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df761482583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df76181e825839000d2a471489a90f2910ec67ded8e215bfcd669bae77e7f9ab15850abd4e130c0bdeb7768edf2e8f85007fd52073e3dc1871f4c47f9dfca92e1828825839000d2a471489a90f2910ec67ded8e215bfcd669bae77e7f9ab15850abd4e130c0bdeb7768edf2e8f85007fd52073e3dc1871f4c47f9dfca92e18320218c7030aa1008282582037139648f2c22bbf1d0ef9af37cfebc9014b1e0e2a55be87c4b3b231a8d84d2658405ef09b22172cd28678e76e600e899886852e03567e2e72b4815629471e736a0cd424dc71cdaa0d0403371d79ea3d0cb7f28cb0740ebfcd8947343eba99a6aa088258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e5840ea98ef8052776aa5c182621cfd2ec91011d327527fc2531be9e1a8356c10f25f3fe5a5a7f549a0dc3b17c4ad8e4b8673b63a87977ac899b675f3ce3d6badae01f6"

-- | Transaction which registers a stake key
txbRegisterStake :: TxBody ShelleyEra
txbRegisterStake =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.fromList [RegTxCert aliceSHK]
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txRegisterStake :: ShelleyTx ShelleyEra
txRegisterStake =
  ShelleyTx
    { stBody = txbRegisterStake
    , stWits =
        mempty
          { addrWits = mkWitnessesVKey (hashAnnotated txbRegisterStake) [alicePay]
          }
    , stAuxData = SNothing
    }

txRegisterStakeBytes16 :: BSL.ByteString
txRegisterStakeBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a048182008200581cc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df76a100818258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e58403271792b002eb39bcb133668e851a5ffba9c13ad2b5c5a7bbc850a17de8309cbb9649d9e90eb4c9cc82f28f204408d513ccc575ce1f61808f67793429ff1880ef6"

-- | Transaction which delegates a stake key
txbDelegateStake :: TxBody ShelleyEra
txbDelegateStake =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts =
        StrictSeq.fromList
          [ DelegStakeTxCert bobSHK alicePoolKH
          ]
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txDelegateStake :: ShelleyTx ShelleyEra
txDelegateStake =
  ShelleyTx
    { stBody = txbDelegateStake
    , stWits =
        mempty
          { addrWits =
              mkWitnessesVKey
                (hashAnnotated txbDelegateStake)
                [asWitness alicePay, asWitness bobStake]
          }
    , stAuxData = SNothing
    }

txDelegateStakeBytes16 :: BSL.ByteString
txDelegateStakeBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a048183028200581c4e130c0bdeb7768edf2e8f85007fd52073e3dc1871f4c47f9dfca92e581c5d43e1f1048b2619f51abc0cf505e4d4f9cb84becefd468d1a2fe335a100828258209921fa37a7d167aab519bb937d7ac6e522ad6d259a6173523357b971e05f41ff58403bad563c201b4f62448db12711af2d916776194b5176e9d312d07a328ce7780a63032dce887abc67985629b7aeabb0c334e84094f44d7e51ae51b5c799a83c0d8258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e584064aef85b046d2d0072cd64844e9f13d86651a1db74d356a10ecd7fb35a664fc466e543ea55cfbffd74025dc092d62c4b22d7e2de4decb4f049df354cfae9790af6"

-- | Transaction which de-registers a stake key
txbDeregisterStake :: TxBody ShelleyEra
txbDeregisterStake =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.fromList [UnRegTxCert aliceSHK]
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txDeregisterStake :: ShelleyTx ShelleyEra
txDeregisterStake =
  ShelleyTx
    { stBody = txbDeregisterStake
    , stWits =
        mempty
          { addrWits = mkWitnessesVKey (hashAnnotated txbDeregisterStake) [alicePay]
          }
    , stAuxData = SNothing
    }

txDeregisterStakeBytes16 :: BSL.ByteString
txDeregisterStakeBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a048182018200581cc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df76a100818258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e5840409db925fa592b7f4c76e44d738789f4b0ffb2b9cf4567af127121d635491b4eb736e8c92571f1329f14d06aad7ec42ca654ae65eb63b0b01d30cc4454aee80cf6"

-- | Transaction which registers a stake pool
txbRegisterPool :: TxBody ShelleyEra
txbRegisterPool =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.fromList [RegPoolTxCert alicePoolParams]
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txRegisterPool :: ShelleyTx ShelleyEra
txRegisterPool =
  ShelleyTx
    { stBody = txbRegisterPool
    , stWits =
        mempty
          { addrWits = mkWitnessesVKey (hashAnnotated txbRegisterPool) [alicePay]
          }
    , stAuxData = SNothing
    }

txRegisterPoolBytes16 :: BSL.ByteString
txRegisterPoolBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a04818a03581c5d43e1f1048b2619f51abc0cf505e4d4f9cb84becefd468d1a2fe33558208e61e1fa4855ea3aa0b8881a9e2e453c8c73536bdaabb64d36de86ee5a02519a0105d81e82010a581de0c6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df7681581cc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df76818301f66872656c61792e696f826a616c6963652e706f6f6c427b7da100818258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e5840165c6aa107571daafb1f9093d3cdc184a4068e8ff9243715c13335feb3652dc0d817b3b015a9929c9d83a0dd406fe71658fdccbf7925d2fff316237b499c2003f6"

-- | Transaction which retires a stake pool
txbRetirePool :: TxBody ShelleyEra
txbRetirePool =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.fromList [RetirePoolTxCert alicePoolKH (EpochNo 5)]
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txRetirePool :: ShelleyTx ShelleyEra
txRetirePool =
  ShelleyTx
    { stBody = txbRetirePool
    , stWits =
        mempty
          { addrWits = mkWitnessesVKey (hashAnnotated txbRetirePool) [alicePay]
          }
    , stAuxData = SNothing
    }

txRetirePoolBytes16 :: BSL.ByteString
txRetirePoolBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a04818304581c5d43e1f1048b2619f51abc0cf505e4d4f9cb84becefd468d1a2fe33505a100818258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e58404ad8f782368857f26db548d4ef6eca276639db9f1e8536f505c049ec94e0f6325c5f9f62a5187eb077f51bcd51cdff7d142415796442f2631081b90bf74f7204f6"

-- | Simple Transaction which consumes one UTxO and creates one UTxO
-- | and has one witness
md :: Era era => ShelleyTxAuxData era
md = ShelleyTxAuxData $ Map.singleton 0 (List [I 5, S "hello"])

txbWithMD :: TxBody ShelleyEra
txbWithMD =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.empty
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SJust $ hashTxAuxData @ShelleyEra md
    }

txWithMD :: ShelleyTx ShelleyEra
txWithMD =
  ShelleyTx
    { stBody = txbWithMD
    , stWits =
        mempty
          { addrWits = mkWitnessesVKey (hashAnnotated txbWithMD) [alicePay]
          }
    , stAuxData = SJust md
    }

txWithMDBytes16 :: BSL.ByteString
txWithMDBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a075820e2d7de09439ab222111cecd21545c5f9c338fd6653539031eb311d34fc97e718a100818258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e5840ab05c3933f5c7281386309a374f45eeee28b6f3a01bc76a5fa3bc9efdc603dd63059d0aebfd198e23bf848dae43a23be3e6f85149bca2f27d0e7f4f63be38e02a10082056568656c6c6f"

-- | Spending from a multi-sig address
msig :: forall era. ShelleyEraScript era => NativeScript era
msig =
  RequireMOf
    2
    ( StrictSeq.fromList
        [ (RequireSignature . asWitness . hashKey . vKey) alicePay
        , (RequireSignature . asWitness . hashKey . vKey) bobPay
        , (RequireSignature . asWitness . hashKey . vKey) carlPay
        ]
    )

txbWithMultiSig :: TxBody ShelleyEra
txbWithMultiSig =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound] -- acting as if this is multi-sig
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.empty
    , stbWithdrawals = Withdrawals Map.empty
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txWithMultiSig :: ShelleyTx ShelleyEra
txWithMultiSig =
  ShelleyTx
    { stBody = txbWithMultiSig
    , stWits =
        mkBasicTxWits
          & addrTxWitsL .~ mkWitnessesVKey (hashAnnotated txbWithMultiSig) [alicePay, bobPay]
          & scriptTxWitsL .~ Map.singleton (hashScript @ShelleyEra msig) msig
    , stAuxData = SNothing
    }

txWithMultiSigBytes16 :: BSL.ByteString
txWithMultiSigBytes16 =
  "83a4008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030aa2008282582037139648f2c22bbf1d0ef9af37cfebc9014b1e0e2a55be87c4b3b231a8d84d265840e3b8f50632325fbd1f82202ce5a8b4672bd96c50a338d70c0aa96720f6f7fbf60e0ce708f3a7e28faa0d78dc437a0b61e02205ddb1db22d02ba35b37a7fe03068258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e584089c20cb6246483bbd0b2006f658597eff3e8ab3b8a6e9b22cb3c5b95cf0d3a2b96107acef88319fa2dd0fb28adcfdb330bb99f1f0058918a75d951ca9b73660c0181830302838200581ce9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371f8200581c0d2a471489a90f2910ec67ded8e215bfcd669bae77e7f9ab15850abd8200581cd0671052191a58c554eee27808b2b836a03ca369ca7a847f8c37d6f9f6"

-- | Transaction with a Reward Withdrawal
txbWithWithdrawal :: TxBody ShelleyEra
txbWithWithdrawal =
  ShelleyTxBody
    { stbInputs = Set.fromList [TxIn genesisId minBound]
    , stbOutputs = StrictSeq.fromList [ShelleyTxOut aliceAddr (Val.inject $ Coin 10)]
    , stbCerts = StrictSeq.empty
    , stbWithdrawals =
        Withdrawals $ Map.singleton (RewardAccount Testnet aliceSHK) (Val.inject $ Coin 100)
    , stbTxFee = Coin 94
    , stbTTL = SlotNo 10
    , stbUpdate = SNothing
    , stbMDHash = SNothing
    }

txWithWithdrawal :: ShelleyTx ShelleyEra
txWithWithdrawal =
  ShelleyTx
    { stBody = txbWithWithdrawal
    , stWits =
        mempty
          { addrWits =
              mkWitnessesVKey
                (hashAnnotated txbWithWithdrawal)
                [asWitness alicePay, asWitness aliceStake]
          }
    , stAuxData = SNothing
    }

txWithWithdrawalBytes16 :: BSL.ByteString
txWithWithdrawalBytes16 =
  "83a5008182582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131400018182583900e9686d801fa32aeb4390c2f2a53bb0314a9c744c46a2cada394a371fc6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df760a02185e030a05a1581de0c6852b6aaed73bcf346a57ef99adae3000b51c7c59faaeb15993df761864a100828258208f40b25c9987eeb9c7f75eaf4f461f16384872a94dc353a4fb5c95bb657c59f85840c52adcbc184a497d1746ee962a762427e79e3f600a356378ffda6294c658ed91c0f0c7815cbaefb22bdabc09c5bf6c5f6724c0136701da26c77882f739f109038258204628aaf16d6e1baa061d1296419542cb09287c639163d0fdbdac0ff23699797e584012d30a6d3dbe0223e772dc183c138779449cd5fd9aac817b63af945b0a8e9f85be3bcc4457ad1a27f08fd36205717f8bafea1b1328f3a074febcfc62b6b99f06f6"

-- | The transaction fee of txSimpleUTxO if one key witness were to be added,
-- given minfeeA and minfeeB are set to 1.
testEstimateMinFee :: Assertion
testEstimateMinFee =
  estimateMinFeeTx @ShelleyEra
    pp
    txSimpleUTxONoWit
    1
    0
    0
    @?= getShelleyMinFeeTxUtxo pp txSimpleUTxO
  where
    pp =
      emptyPParams
        & ppMinFeeAL .~ Coin 1
        & ppMinFeeBL .~ Coin 1

    txSimpleUTxONoWit =
      ShelleyTx
        { stBody = txbSimpleUTxO
        , stWits = mempty
        , stAuxData = SNothing
        }

-- NOTE the txsize function takes into account which actual crypto parameter is in use.
-- These tests are using Blake2b and Ed25519 so that:
--       the regular hash length is ----> 32
--       the address hash length is ----> 28
--       the verification key size is --> 32
--       the signature size is ---------> 64

sizeTests :: TestTree
sizeTests =
  testGroup
    "Fee Tests"
    [ testCase "simple utxo" $ sizeTest txSimpleUTxOBytes16 txSimpleUTxO
    , testCase "multiple utxo" $ sizeTest txMutiUTxOBytes16 txMutiUTxO
    , testCase "register stake key" $ sizeTest txRegisterStakeBytes16 txRegisterStake
    , testCase "delegate stake key" $ sizeTest txDelegateStakeBytes16 txDelegateStake
    , testCase "deregister stake key" $ sizeTest txDeregisterStakeBytes16 txDeregisterStake
    , testCase "register stake pool" $ sizeTest txRegisterPoolBytes16 txRegisterPool
    , testCase "retire stake pool" $ sizeTest txRetirePoolBytes16 txRetirePool
    , testCase "auxiliaryData" $ sizeTest txWithMDBytes16 txWithMD
    , testCase "multisig" $ sizeTest txWithMultiSigBytes16 txWithMultiSig
    , testCase "reward withdrawal" $ sizeTest txWithWithdrawalBytes16 txWithWithdrawal
    , testCase "estimate transaction fee" testEstimateMinFee
    ]
