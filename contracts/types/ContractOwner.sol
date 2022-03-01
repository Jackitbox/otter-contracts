// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import './Ownable.sol';

interface IContractOwner {
    function pushContractManagement(address contract_, address newOwner_) external;

    function pullContractManagement(address contract_) external;
}

abstract contract ContractOwner is Ownable {
    function pushContractManagement(address contract_, address newOwner_) external onlyOwner {
        IOwnable(contract_).pushManagement(newOwner_);
    }

    function pullContractManagement(address contract_) external onlyOwner {
        IOwnable(contract_).pullManagement();
    }
}
