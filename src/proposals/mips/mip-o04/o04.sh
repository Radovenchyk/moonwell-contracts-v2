#!/bin/bash
export MTOKENS_PATH=src/proposals/mips/mip-o04/MTokens.json
echo "MTOKENS_PATH=$MTOKENS_PATH"

export EMISSION_CONFIGURATIONS_PATH=src/proposals/mips/mip-o04/RewardStreams.json
echo "EMISSION_CONFIGURATIONS_PATH=$EMISSION_CONFIGURATIONS_PATH"

export DESCRIPTION_PATH=src/proposals/mips/mip-o04/MIP-O04.md
echo "DESCRIPTION_PATH=$DESCRIPTION_PATH"

export PRIMARY_FORK_ID=2
echo "PRIMARY_FORK_ID=$PRIMARY_FORK_ID"

export EXCLUDE_MARKET_ADD_CHECKER=true
echo "EXCLUDE_MARKET_ADD_CHECKER=$EXCLUDE_MARKET_ADD_CHECKER"
