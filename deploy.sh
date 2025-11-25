#!/bin/bash
set -e

# --- Configuration ---
CONTRACT_NAME="FastPool" # Changed to match your example name
ACCOUNT_NAME="readyone" # The name of your account profile in snfoundry.toml
NETWORK_NAME="sepolia"    # The name of your network profile in snfoundry.toml
OWNER_ADDRESS=${OWNER_ADDRESS:?Error: OWNER_ADDRESS environment variable not set or empty}
SIERRA_PATH="./target/dev/${CONTRACT_NAME}.sierra.json"

echo "Starting deployment process using config profile: $ACCOUNT_NAME on $NETWORK_NAME"
echo "Owner Address: $OWNER_ADDRESS"

# 1. Compile the contract
echo "Building contract..."
scarb build

# 2. Declare the contract using the configured network and account
echo "Declaring contract class..."
DECLARE_OUTPUT=$(sncast declare --network "$NETWORK_NAME" --contract-name "$CONTRACT_NAME")
CLASS_HASH=$(echo "$DECLARE_OUTPUT" | grep 'Class Hash' | awk '{print $NF}')

if [ -z "$CLASS_HASH" ]; then
    echo "Failed to retrieve Class Hash from declare output. Exiting."
    echo "Output was: $DECLARE_OUTPUT"
    exit 1
fi

echo "Contract declared successfully with Class Hash: $CLASS_HASH"

# 3. Deploy the contract with constructor arguments
echo "Deploying contract instance with owner $OWNER_ADDRESS..."
# The constructor argument is passed via the --constructor-calldata flag
DEPLOY_OUTPUT=$(sncast deploy --network "$NETWORK_NAME" --class-hash "$CLASS_HASH" --constructor-calldata "$OWNER_ADDRESS")
CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep 'Contract Address' | awk '{print $NF}')

if [ -z "$CONTRACT_ADDRESS" ]; then
    echo "Failed to retrieve Contract Address from deploy output. Exiting."
    echo "Output was: $DEPLOY_OUTPUT"
    exit 1
fi

echo "Contract deployed successfully at Address: $CONTRACT_ADDRESS"
echo "Deployment Complete."
