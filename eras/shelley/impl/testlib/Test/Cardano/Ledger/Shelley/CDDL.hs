{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- HLINT ignore "Use camelCase" -}
{- HLINT ignore "Evaluate" -}

module Test.Cardano.Ledger.Shelley.CDDL (
  module Test.Cardano.Ledger.Core.Binary.CDDL,
  module Test.Cardano.Ledger.Shelley.CDDL,
) where

import Cardano.Ledger.BaseTypes (getVersion)
import Cardano.Ledger.Core (ByronEra, Era, eraProtVerHigh, eraProtVerLow)
import Cardano.Ledger.Shelley (ShelleyEra)
import Codec.CBOR.Cuddle.Comments ((//-))
import Codec.CBOR.Cuddle.Huddle
import Data.Word (Word64)
import Test.Cardano.Ledger.Core.Binary.CDDL
import Text.Heredoc
import Prelude hiding ((/))

shelleyCDDL :: Huddle
shelleyCDDL = collectFrom [HIRule $ block @ShelleyEra, HIRule $ transaction @ShelleyEra, HIRule signkeyKES]

block :: forall era. Era era => Rule
block =
  "block"
    =:= arr
      [ a $ header @era
      , "transaction_bodies" ==> arr [0 <+ a (transaction_body @era)]
      , "transaction_witness_sets" ==> arr [0 <+ a transaction_witness_set]
      , "transaction_metadata_set" ==> mp [0 <+ asKey transaction_index ==> transaction_metadata]
      ]

transaction :: forall era. Era era => Rule
transaction =
  "transaction"
    =:= arr
      [ a $ transaction_body @era
      , a transaction_witness_set
      , a (transaction_metadata / VNil)
      ]

transaction_index :: Rule
transaction_index = "transaction_index" =:= VUInt `sized` (2 :: Word64)

header :: forall era. Era era => Rule
header = "header" =:= arr [a $ header_body @era, "body_signature" ==> kes_signature]

header_body :: forall era. Era era => Rule
header_body =
  "header_body"
    =:= arr
      [ "block_number" ==> VUInt
      , "slot" ==> VUInt
      , "prev_hash" ==> (hash32 / VNil)
      , "issuer_vkey" ==> vkey
      , "vrf_vkey" ==> vrf_vkey
      , "nonce_vrf" ==> vrf_cert
      , "leader_vrf" ==> vrf_cert
      , "block_body_size" ==> (VUInt `sized` (4 :: Word64))
      , "block_body_hash" ==> hash32
      , a operational_cert
      , a $ protocol_version @era
      ]

operational_cert :: Named Group
operational_cert =
  "operational_cert"
    =:~ grp
      [ "hot_vkey" ==> kes_vkey
      , "sequence_number" ==> VUInt
      , "kes_period" ==> VUInt
      , "sigma" ==> signature
      ]

major_protocol_version :: forall era. Era era => Rule
major_protocol_version =
  "major_protocol_version"
    =:= (getVersion @Integer (eraProtVerLow @ByronEra) ... succ (getVersion @Integer (eraProtVerHigh @era)))

protocol_version :: forall era. Era era => Named Group
protocol_version = "protocol_version" =:~ grp [a $ major_protocol_version @era, a VUInt]

transaction_body :: forall era. Era era => Rule
transaction_body =
  "transaction_body"
    =:= mp
      [ idx 0 ==> set transaction_input
      , idx 1 ==> arr [0 <+ a transaction_output]
      , idx 2 ==> coin
      , idx 3 ==> VUInt
      , opt (idx 4 ==> arr [0 <+ a certificate])
      , opt (idx 5 ==> withdrawals)
      , opt (idx 6 ==> update @era)
      , opt (idx 7 ==> metadata_hash)
      ]

transaction_input :: Rule
transaction_input =
  "transaction_input"
    =:= arr
      [ "id" ==> transaction_id
      , "index" ==> VUInt `sized` (2 :: Word64)
      ]

transaction_id :: Rule
transaction_id =
  "transaction_id" =:= hash32

transaction_output :: Rule
transaction_output = "transaction_output" =:= arr [a address, "amount" ==> coin]

certificate :: Rule
certificate =
  "certificate"
    =:= arr [a stake_registration]
    / arr [a stake_deregistration]
    / arr [a stake_delegation]
    / arr [a pool_registration]
    / arr [a pool_retirement]
    / arr [a genesis_key_delegation]
    / arr [a move_instantaneous_rewards_cert]

stake_registration :: Named Group
stake_registration =
  comment "This will be deprecated in a future era" $
    "stake_registration" =:~ grp [0, a stake_credential]

stake_deregistration :: Named Group
stake_deregistration =
  comment "This will be deprecated in a future era" $
    "stake_deregistration" =:~ grp [1, a stake_credential]

stake_delegation :: Named Group
stake_delegation = "stake_delegation" =:~ grp [2, a stake_credential, a pool_keyhash]

pool_registration :: Named Group
pool_registration = "pool_registration" =:~ grp [3, a pool_params]

pool_retirement :: Named Group
pool_retirement = "pool_retirement" =:~ grp [4, a pool_keyhash, a epoch]

genesis_key_delegation :: Named Group
genesis_key_delegation =
  "genesis_key_delegation"
    =:~ grp [5, a genesis_hash, a genesis_delegate_hash, a vrf_keyhash]

move_instantaneous_rewards_cert :: Named Group
move_instantaneous_rewards_cert =
  "move_instantaneous_rewards_cert"
    =:~ grp [6, a move_instantaneous_reward]

move_instantaneous_reward :: Rule
move_instantaneous_reward =
  comment
    [str|The first field determines where the funds are drawn from.
        |  0 denotes the reserves,
        |  1 denotes the treasury.
        |If the second field is a map, funds are moved to stake credentials.
        |Otherwise, the funds are given to the other accounting pot.
        |NOTE:
        |  This has been safely backported to Shelley from Alonzo.
        |]
    $ "move_instantaneous_reward"
      =:= arr
        [ a (int 0 / int 1)
        , a (smp [0 <+ asKey stake_credential ==> delta_coin] / coin)
        ]

delta_coin :: Rule
delta_coin =
  comment
    [str|This too has been introduced in Shelley as a backport from Alonzo.
        |]
    $ "delta_coin" =:= VInt

stake_credential :: Rule
stake_credential = "stake_credential" =:= credential

credential :: Rule
credential = "credential" =:= arr [0, a addr_keyhash] / arr [1, a script_hash]

pool_params :: Named Group
pool_params =
  "pool_params"
    =:~ grp
      [ "operator" ==> pool_keyhash
      , "vrf_keyhash" ==> vrf_keyhash
      , "pledge" ==> coin
      , "cost" ==> coin
      , "margin" ==> unit_interval
      , "reward_account" ==> reward_account
      , "pool_owners" ==> set addr_keyhash
      , "relays" ==> arr [0 <+ a relay]
      , "pool_metadata" ==> (pool_metadata / VNil)
      ]

port :: Rule
port = "port" =:= VUInt `le` 65535

ipv4 :: Rule
ipv4 = "ipv4" =:= VBytes `sized` (4 :: Word64)

ipv6 :: Rule
ipv6 = "ipv6" =:= VBytes `sized` (16 :: Word64)

dns_name :: Rule
dns_name = "dns_name" =:= VText `sized` (0 :: Word64, 64 :: Word64)

single_host_addr :: Named Group
single_host_addr =
  "single_host_addr" =:~ grp [0, a $ port / VNil, a $ ipv4 / VNil, a $ ipv6 / VNil]

single_host_name :: Named Group
single_host_name =
  comment
    [str|dns_name: An A or AAAA DNS record
        |]
    $ "single_host_name" =:~ grp [1, a $ port / VNil, a dns_name]

multi_host_name :: Named Group
multi_host_name =
  comment
    [str|dns_name: An SRV DNS record
        |]
    $ "multi_host_name" =:~ grp [2, a dns_name]

relay :: Rule
relay =
  "relay"
    =:= arr [a single_host_addr]
    / arr [a single_host_name]
    / arr [a multi_host_name]

pool_metadata :: Rule
pool_metadata = "pool_metadata" =:= arr [a url, a VBytes]

url :: Rule
url = "url" =:= VText `sized` (0 :: Word64, 64 :: Word64)

withdrawals :: Rule
withdrawals = "withdrawals" =:= mp [0 <+ asKey reward_account ==> coin]

update :: forall era. Era era => Rule
update = "update" =:= arr [a $ proposed_protocol_parameter_updates @era, a epoch]

proposed_protocol_parameter_updates :: forall era. Era era => Rule
proposed_protocol_parameter_updates =
  "proposed_protocol_parameter_updates"
    =:= mp [0 <+ asKey genesis_hash ==> protocol_param_update @era]

protocol_param_update :: forall era. Era era => Rule
protocol_param_update =
  "protocol_param_update"
    =:= mp
      [ opt (idx 0 ==> VUInt) //- "minfee A"
      , opt (idx 1 ==> VUInt) //- "minfee B"
      , opt (idx 2 ==> VUInt) //- "max block body size"
      , opt (idx 3 ==> VUInt) //- "max transaction size"
      , opt (idx 4 ==> (VUInt `sized` (2 :: Word64))) //- "max block header size"
      , opt (idx 5 ==> coin) //- "key deposit"
      , opt (idx 6 ==> coin) //- "pool deposit"
      , opt (idx 7 ==> epoch) //- "maximum epoch"
      , opt (idx 8 ==> VUInt `sized` (2 :: Word64)) //- "n_opt: desired number of stake pools"
      , opt (idx 9 ==> nonnegative_interval) //- "pool pledge influence"
      , opt (idx 10 ==> unit_interval) //- "expansion rate"
      , opt (idx 11 ==> unit_interval) //- "treasury growth rate"
      , opt (idx 12 ==> unit_interval) //- "decentralization constant"
      , opt (idx 13 ==> nonce) //- "extra entropy"
      , opt (idx 14 ==> arr [a $ protocol_version @era]) //- "protocol version"
      , opt (idx 15 ==> coin) //- "min utxo value"
      , opt (idx 16 ==> coin) //- "min pool cost"
      ]

transaction_witness_set :: Rule
transaction_witness_set =
  "transaction_witness_set"
    =:= mp
      [ opt $ idx 0 ==> arr [0 <+ a vkeywitness]
      , opt $ idx 1 ==> arr [0 <+ a multisig_script]
      , opt $ idx 2 ==> arr [0 <+ a bootstrap_witness]
      ]

transaction_metadatum :: Rule
transaction_metadatum =
  "transaction_metadatum"
    =:= smp [0 <+ asKey transaction_metadatum ==> transaction_metadatum]
    / sarr [0 <+ a transaction_metadatum]
    / VInt
    / (VBytes `sized` (0 :: Word64, 64 :: Word64))
    / (VText `sized` (0 :: Word64, 64 :: Word64))

transaction_metadatum_label :: Rule
transaction_metadatum_label = "transaction_metadatum_label" =:= VUInt

transaction_metadata :: Rule
transaction_metadata =
  "transaction_metadata"
    =:= mp [0 <+ asKey transaction_metadatum_label ==> transaction_metadatum]

vkeywitness :: Rule
vkeywitness = "vkeywitness" =:= arr [a vkey, a signature]

bootstrap_witness :: Rule
bootstrap_witness =
  "bootstrap_witness"
    =:= arr
      [ "public_key" ==> vkey
      , "signature" ==> signature
      , "chain_code" ==> (VBytes `sized` (32 :: Word64))
      , "attributes" ==> VBytes
      ]

multisig_script :: Rule
multisig_script =
  "multisig_script"
    =:= arr [a multisig_pubkey]
    / arr [a multisig_all]
    / arr [a multisig_any]
    / arr [a multisig_n_of_k]

multisig_pubkey :: Named Group
multisig_pubkey = "multisig_pubkey" =:~ grp [0, a addr_keyhash]

multisig_all :: Named Group
multisig_all = "multisig_all" =:~ grp [1, a (arr [0 <+ a multisig_script])]

multisig_any :: Named Group
multisig_any = "multisig_any" =:~ grp [2, a (arr [0 <+ a multisig_script])]

multisig_n_of_k :: Named Group
multisig_n_of_k = "multisig_n_of_k" =:~ grp [3, "n" ==> VUInt, a (arr [0 <+ a multisig_script])]

epoch :: Rule
epoch = "epoch" =:= VUInt

genesis_delegate_hash :: Rule
genesis_delegate_hash = "genesis_delegate_hash" =:= hash28

genesis_hash :: Rule
genesis_hash = "genesis_hash" =:= hash28

script_hash :: Rule
script_hash =
  comment
    [str|To compute a script hash, note that you must prepend
        |a tag to the bytes of the script before hashing.
        |The tag is determined by the language.
        |The tags in the Conway era are:
        |  "\x00" for multisig scripts
        |  "\x01" for Plutus V1 scripts
        |  "\x02" for Plutus V2 scripts
        |  "\x03" for Plutus V3 scripts
        |]
    $ "script_hash" =:= hash28

metadata_hash :: Rule
metadata_hash = "metadata_hash" =:= hash32

nonce :: Rule
nonce = "nonce" =:= arr [0] / arr [1, a (VBytes `sized` (32 :: Word64))]

-- Shelley does not support some of the tagged core datastructures that we rely
-- on in future eras. In order to have the "correct" common specification in
-- core, we override them here
set :: IsType0 t0 => t0 -> GRuleCall
set = binding $ \x -> "set" =:= arr [0 <+ a x]

nonempty_set :: IsType0 t0 => t0 -> GRuleCall
nonempty_set = binding $ \x -> "nonempty_set" =:= arr [1 <+ a x]
