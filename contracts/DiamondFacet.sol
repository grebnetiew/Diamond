pragma solidity ^0.6.4;
pragma experimental ABIEncoderV2;

/******************************************************************************\
* Author: Nick Mudge
*
* Implementation of Diamond facet.
* This is gas optimized by reducing storage reads and storage writes.
/******************************************************************************/

import "./DiamondStorageContract.sol";
import "./DiamondHeaders.sol";

contract DiamondFacet is Diamond, DiamondStorageContract {
    bytes32 constant CLEAR_ADDRESS_MASK = 0x0000000000000000000000000000000000000000ffffffffffffffffffffffff;
    bytes32 constant CLEAR_SELECTOR_MASK = 0xffffffff00000000000000000000000000000000000000000000000000000000;

    struct SlotInfo {
        uint originalSelectorSlotsLength;
        bytes32 selectorSlot;
        uint oldSelectorSlotsIndex;
        uint oldSelectorSlotIndex;
        bytes32 oldSelectorSlot;
        bool newSlot;
    }

    function diamondCut(bytes[] memory _diamondCut) public override {
        DiamondStorage storage ds = diamondStorage();
        require(msg.sender == ds.contractOwner, "Must own the contract.");
        SlotInfo memory slot;
        slot.originalSelectorSlotsLength = ds.selectorSlotsLength;
        // Unpack selectorSlotsLength, which is a concatenation of the array length
        // and the number of selectors in the last slot in the array
        uint selectorSlotArrayLength = uint128(slot.originalSelectorSlotsLength);
        uint selectorFinalSlotLength = uint128(slot.originalSelectorSlotsLength >> 128);
        // If the last slot contains any selectors, load them
        if(selectorFinalSlotLength > 0) {
            slot.selectorSlot = ds.selectorSlots[selectorSlotArrayLength]; // ??? -1?
        }
        // Loop through the edited facets in the diamond cut
        for(uint diamondCutIndex; diamondCutIndex < _diamondCut.length; diamondCutIndex++) {
            bytes memory facetCut = _diamondCut[diamondCutIndex];
            // A facet cut should have an address (length 20) and at least one selector
            require(facetCut.length > 20, "Missing facet or selector info.");
            // Load the new facet address. In memory, the 'bytes' type is a uint256 length
            // followed by the byte values, the first 20 of which are the facet address.
            // We mload the contents (mload loads 32 bytes) and truncate it to 20.
            bytes32 currentSlot;
            assembly {
                currentSlot := mload(add(facetCut,32))
            }
            bytes32 newFacet = bytes20(currentSlot);
            uint numSelectors = (facetCut.length - 20) / 4;
            uint position = 52; // (length = 32 + address_bytes = 20)
            
            // adding or replacing functions
            if(newFacet != 0) {
                // add and replace selectors
                for(uint selectorIndex; selectorIndex < numSelectors; selectorIndex++) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(facetCut,position))
                    }
                    position += 4;
                    bytes32 oldFacet = ds.facets[selector];
                    // add
                    if(oldFacet == 0) {
                        ds.facets[selector] = newFacet | bytes32(selectorFinalSlotLength) << 64 | bytes32(selectorSlotArrayLength);
                        slot.selectorSlot = slot.selectorSlot & ~(CLEAR_SELECTOR_MASK >> selectorFinalSlotLength * 32) | bytes32(selector) >> selectorFinalSlotLength * 32;
                        selectorFinalSlotLength++;
                        if(selectorFinalSlotLength == 8) {
                            ds.selectorSlots[selectorSlotArrayLength] = slot.selectorSlot;
                            slot.selectorSlot = 0;
                            selectorFinalSlotLength = 0;
                            selectorSlotArrayLength++;
                            slot.newSlot = false;
                        }
                        else {
                            slot.newSlot = true;
                        }
                    }
                    // replace
                    else {
                        require(bytes20(oldFacet) != bytes20(newFacet), "Function cut to same facet.");
                        ds.facets[selector] = oldFacet & CLEAR_ADDRESS_MASK | newFacet;
                    }
                }
            }
            // remove functions
            else {
                for(uint selectorIndex; selectorIndex < numSelectors; selectorIndex++) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(facetCut,position))
                    }
                    position += 4;
                    bytes32 oldFacet = ds.facets[selector];
                    require(oldFacet != 0, "Function doesn't exist. Can't remove.");
                    if(slot.selectorSlot == 0) {
                        selectorSlotArrayLength--;
                        slot.selectorSlot = ds.selectorSlots[selectorSlotArrayLength];
                        selectorFinalSlotLength = 8;
                    }
                    slot.oldSelectorSlotsIndex = uint64(uint(oldFacet));
                    slot.oldSelectorSlotIndex = uint32(uint(oldFacet >> 64));
                    bytes4 lastSelector = bytes4(slot.selectorSlot << (selectorFinalSlotLength-1) * 32);
                    if(slot.oldSelectorSlotsIndex != selectorSlotArrayLength) {
                        slot.oldSelectorSlot = ds.selectorSlots[slot.oldSelectorSlotsIndex];
                        slot.oldSelectorSlot = slot.oldSelectorSlot & ~(CLEAR_SELECTOR_MASK >> slot.oldSelectorSlotIndex * 32) | bytes32(lastSelector) >> slot.oldSelectorSlotIndex * 32;
                        ds.selectorSlots[slot.oldSelectorSlotsIndex] = slot.oldSelectorSlot;
                        selectorFinalSlotLength--;
                    }
                    else {
                        slot.selectorSlot = slot.selectorSlot & ~(CLEAR_SELECTOR_MASK >> slot.oldSelectorSlotIndex * 32) | bytes32(lastSelector) >> slot.oldSelectorSlotIndex * 32;
                        selectorFinalSlotLength--;
                    }
                    if(selectorFinalSlotLength == 0) {
                        delete ds.selectorSlots[selectorSlotArrayLength];
                        slot.selectorSlot = 0;
                    }
                    if(lastSelector != selector) {
                        ds.facets[lastSelector] = oldFacet & CLEAR_ADDRESS_MASK | bytes20(ds.facets[lastSelector]);
                    }
                    delete ds.facets[selector];
                }
            }
        }
        uint newSelectorSlotsLength = selectorFinalSlotLength << 128 | selectorSlotArrayLength;
        if(newSelectorSlotsLength != slot.originalSelectorSlotsLength) {
            ds.selectorSlotsLength = newSelectorSlotsLength;
        }
        if(slot.newSlot) {
            ds.selectorSlots[selectorSlotArrayLength] = slot.selectorSlot;
        }
        emit DiamondCut(_diamondCut);
    }
}
