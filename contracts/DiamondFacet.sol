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

    // To save on writes to the storage, keep a cache of the selector slot in memory
    // while we're filling it up. This is the cache structure.
    struct SlotInfo {
        uint originalSelectorSlotsLength;
        bytes32 selectorSlot;
        uint oldSelectorArrayIndex;
        uint oldSelectorIndexWithinSlot;
        bytes32 oldSelectorSlot;
        bool newSlot;
    }

    function diamondCut(bytes[] memory _diamondCut) public override {
        DiamondStorage storage ds = diamondStorage();
        require(msg.sender == ds.contractOwner, "Must own the contract.");
        SlotInfo memory slot;
        slot.originalSelectorSlotsLength = ds.selectorSlotsLength;
        // Unpack selectorSlotsLength, which is a concatenation of the number of
        // full slots and the number of selectors in the last slot in the array
        uint selectorNumFullSlots = uint128(slot.originalSelectorSlotsLength);
        uint selectorFinalSlotLength = uint128(slot.originalSelectorSlotsLength >> 128);
        // If the last slot contains any selectors, load them
        if(selectorFinalSlotLength > 0) {
            slot.selectorSlot = ds.selectorSlots[selectorNumFullSlots];
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
                currentSlot := mload(add(facetCut, 32))
            }
            bytes32 newFacet = bytes20(currentSlot);
            uint numSelectors = (facetCut.length - 20) / 4;
            uint position = 52; // (length_uint256 = 32 + facet_address = 20)
            
            // adding or replacing functions
            if(newFacet != 0) {
                // add and replace selectors
                for(uint selectorIndex; selectorIndex < numSelectors; selectorIndex++) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(facetCut, position))
                    }
                    position += 4;
                    bytes32 oldFacet = ds.facets[selector];
                    // add a selector
                    if(oldFacet == 0) {
                        // The new facet is the concatenation of the address and the place of the function selector in the
                        // selector slots array; this location is 'past the end' since we'll add it there
                        ds.facets[selector] = newFacet | bytes32(selectorFinalSlotLength) << 64 | bytes32(selectorNumFullSlots);
                        // The new selector is also saved in the selector slots array
                        slot.selectorSlot = slot.selectorSlot & ~(CLEAR_SELECTOR_MASK >> selectorFinalSlotLength * 32) | bytes32(selector) >> selectorFinalSlotLength * 32;
                        // Bookkeeping: if this fills up the slot, allocate a new one
                        selectorFinalSlotLength++;
                        if(selectorFinalSlotLength == 8) {
                            ds.selectorSlots[selectorNumFullSlots] = slot.selectorSlot;
                            slot.selectorSlot = 0;
                            selectorFinalSlotLength = 0;
                            selectorNumFullSlots++;
                            // Since we manually wrote the cache to storage, no need to mark it dirty
                            slot.newSlot = false;
                        }
                        else {
                            // We changed the selector slot cache; mark dirty and write to storage at the end
                            slot.newSlot = true;
                        }
                    }
                    // replace a selector
                    else {
                        require(bytes20(oldFacet) != bytes20(newFacet), "Function cut to same facet.");
                        ds.facets[selector] = oldFacet & CLEAR_ADDRESS_MASK | newFacet;
                    }
                }
            }
            // remove functions
            else {
                for(uint selectorIndex; selectorIndex < numSelectors; selectorIndex++) {
                    // Load the selector to be removed from the argument and make sure it's registered
                    bytes4 selector;
                    assembly {
                        selector := mload(add(facetCut, position))
                    }
                    position += 4;
                    bytes32 oldFacet = ds.facets[selector];
                    require(oldFacet != 0, "Function doesn't exist. Can't remove.");

                    // We'll shrink the selector storage by one. If the last slot is empty, we'll
                    // remove one from the slot before that. So, load it.
                    if(slot.selectorSlot == 0) {
                        selectorNumFullSlots--;
                        slot.selectorSlot = ds.selectorSlots[selectorNumFullSlots];
                        selectorFinalSlotLength = 8;
                    }
                    // Load the location of the slot to be removed in the selector slot array
                    slot.oldSelectorArrayIndex = uint64(uint(oldFacet));
                    slot.oldSelectorIndexWithinSlot = uint32(uint(oldFacet >> 64));
                    // We'll swap the last selector in the last occupied slot with the one
                    // that'll be removed, so load it now
                    bytes4 lastSelector = bytes4(slot.selectorSlot << (selectorFinalSlotLength-1) * 32);
                    // If the selector we'll remove is in another slot, load that one and do the swap
                    if(slot.oldSelectorArrayIndex != selectorNumFullSlots) {
                        slot.oldSelectorSlot = ds.selectorSlots[slot.oldSelectorArrayIndex];
                        slot.oldSelectorSlot = slot.oldSelectorSlot & ~(CLEAR_SELECTOR_MASK >> slot.oldSelectorIndexWithinSlot * 32) | bytes32(lastSelector) >> slot.oldSelectorIndexWithinSlot * 32;
                        ds.selectorSlots[slot.oldSelectorArrayIndex] = slot.oldSelectorSlot;
                        selectorFinalSlotLength--;
                    }
                    // If the selector we'll remove is in the same slot, swap immediately
                    else {
                        slot.selectorSlot = slot.selectorSlot & ~(CLEAR_SELECTOR_MASK >> slot.oldSelectorIndexWithinSlot * 32) | bytes32(lastSelector) >> slot.oldSelectorIndexWithinSlot * 32;
                        selectorFinalSlotLength--;
                    }
                    // If the last slot is now empty, we remove it from the array
                    if(selectorFinalSlotLength == 0) {
                        delete ds.selectorSlots[selectorNumFullSlots];
                        slot.selectorSlot = 0;
                    }
                    // Also make sure the new location of the formerly last selector is correctly
                    // tracked in the facets array
                    if(lastSelector != selector) {
                        ds.facets[lastSelector] = oldFacet & CLEAR_ADDRESS_MASK | bytes20(ds.facets[lastSelector]);
                    }

                    delete ds.facets[selector];
                }
            }
        }
        // Update selector slot length in storage
        uint newSelectorSlotsLength = selectorFinalSlotLength << 128 | selectorNumFullSlots;
        if(newSelectorSlotsLength != slot.originalSelectorSlotsLength) {
            ds.selectorSlotsLength = newSelectorSlotsLength;
        }
        // Write slot cache to storage if it is marked dirty
        if(slot.newSlot) {
            ds.selectorSlots[selectorNumFullSlots] = slot.selectorSlot;
        }
        // ??? I don't think the dirty flag is ever set during removal. Intentional?

        emit DiamondCut(_diamondCut);
    }
}
