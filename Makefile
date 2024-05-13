-include .env

.PHONY: deploy

deploy :; @forge script script/DeployDTsla.s.sol --private-key ${PRIVATE_KEY} --rpc-url ${SEPOLIA_RPC_URL} --etherscan-api-key ${ETHERSCAN_API_KEY} --verify --broadcast 
 

#--verify --broadcast