-include .env

.PHONY: deploy

deploy :; @forge script script/DeployDTsla.s.sol --private-key ${PRIVATE_KEY} --rpc-url ${POLYGON_RPC_URL} --broadcast 
#verify :; @forge verify-contract --chain-id 80002 --verifier-url https://api-amoy.polygonscan.com/api ${CONTRACT_ADDRESS} src/dTsla.sol:dTsla ${AMOY_API_KEY}
verify :; @forge verify-contract ${CONTRACT_ADDRESS} src/dTsla.sol:dTsla --chain polygon-amoy
#--verify --broadcast