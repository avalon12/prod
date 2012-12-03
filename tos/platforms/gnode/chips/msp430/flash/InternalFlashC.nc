// $Id: InternalFlashC.nc,v 1.1 2007/07/11 00:42:57 razvanm Exp $

/*									tab:4
 *
 *
 * "Copyright (c) 2000-2004 The Regents of the University  of California.  
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without written agreement is
 * hereby granted, provided that the above copyright notice, the following
 * two paragraphs and the author appear in all copies of this software.
 * 
 * IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
 * OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF THE UNIVERSITY OF
 * CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 * 
 * THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS
 * ON AN "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATION TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS."
 *
 */

/**
 * InternalFlashC.nc - Internal flash implementation for telos msp
 * platform. On the msp, the flash must first be erased before a value
 * can be written. However, the msp can only erase the flash at a
 * segment granularity (128 bytes for the information section). This
 * module allows transparent read/write of individual bytes to the
 * information section by dynamically switching between the two
 * provided segments in the information section.
 *
 * Valid address range is 0x1000 - 0x107E (0x107F is used to store the
 * version number of the information segment).
 *
 * @author Jonathan Hui <jwhui@cs.berkeley.edu>
 * 
 * Reformatted and added needed atomic blocks.
 * Added support for the 2xx flash memory layout.
 * @author Michiel Konstapel
 */

#include "Assert.h"

module InternalFlashC {
	provides interface InternalFlash;
}

implementation {

	enum {
		ASSERT_IFLASH_OUT_OF_BOUNDS = unique(UQ_ASSERT)
	};
	
	// the 1xx devices have two 128 byte segments, while the 2xx devices have four 64-byte segments,
	// of which the last one (segment A) holds configuration data and is by default not erased
	#ifdef __MSP430_HAS_FLASH2__
		#define IFLASH_SIZE 64
	#else
		#define IFLASH_SIZE 128
	#endif
	
	enum {
		IFLASH_OFFSET     = 0x1000,
		IFLASH_SEG0_VNUM_ADDR = IFLASH_OFFSET + IFLASH_SIZE - 1,
		IFLASH_SEG1_VNUM_ADDR = IFLASH_OFFSET + IFLASH_SIZE + IFLASH_SIZE - 1,
		IFLASH_INVALID_VNUM = -1,
	};

	uint8_t chooseSegment() {
		int8_t vnum0 = *(int8_t*)IFLASH_SEG0_VNUM_ADDR;
		int8_t vnum1 = *(int8_t*)IFLASH_SEG1_VNUM_ADDR;
		if (vnum0 == IFLASH_INVALID_VNUM)
			return 1;
		else if (vnum1 == IFLASH_INVALID_VNUM)
			return 0;
		return ( (int8_t)(vnum0 - vnum1) < 0 );
	}

	command error_t InternalFlash.write(void* addr, void* buf, uint16_t size) {
		assert((uint16_t) addr + size < IFLASH_SIZE, ASSERT_IFLASH_OUT_OF_BOUNDS);
		
		// writing to flash must be done with interrupts disabled!
		atomic {
			volatile int8_t *newPtr;
			int8_t *oldPtr;
			int8_t *bufPtr = (int8_t*)buf;
			int8_t version;
			uint16_t i;
	
			addr += IFLASH_OFFSET;
			newPtr = oldPtr = (int8_t*)IFLASH_OFFSET;
			if (chooseSegment()) {
				oldPtr += IFLASH_SIZE;
			}
			else {
				addr += IFLASH_SIZE;
				newPtr += IFLASH_SIZE;
			}
	
			FCTL2 = FWKEY + FSSEL1 + FN2;
			FCTL3 = FWKEY;						// clear lock bit
			FCTL1 = FWKEY + ERASE;		// select erase operation
			*newPtr = 0;							// dummy write to erase the segment
			FCTL1 = FWKEY + WRT;			// select write operation
	
			for ( i = 0; i < IFLASH_SIZE-1; i++, newPtr++, oldPtr++ ) {
				if ((uint16_t)newPtr < (uint16_t)addr || (uint16_t)addr+size <= (uint16_t)newPtr)
					*newPtr = *oldPtr;
				else
					*newPtr = *bufPtr++;
			}
			version = *oldPtr + 1;
			if (version == IFLASH_INVALID_VNUM)
				version++;
			*newPtr = version;
	
			FCTL1 = FWKEY;					// clear write bit
			FCTL3 = FWKEY + LOCK;		// set lock bit
		}
		
		return SUCCESS;
	}

	command error_t InternalFlash.read(void* addr, void* buf, uint16_t size) {
		addr += IFLASH_OFFSET;
		if (chooseSegment())
			addr += IFLASH_SIZE;

		memcpy(buf, addr, size);

		return SUCCESS;
	}

}
